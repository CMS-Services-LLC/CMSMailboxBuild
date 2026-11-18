/*  046 - the mailbox's Dynamic Report viewer loads rows without NEO_GetDynamicReportsALL2  (2026-11-18)

    "This report couldn't be loaded" (Action Request report link, sql/045): DRViewController.Report
    called CMS's NEO_GetDynamicReportsALL2, which since drt_001 (2026-11-17) only returns rows to
    people with every report type (ftnDRFullAccess) or a Team Group for the report's type. With no
    rows its dynamic pivot becomes "for Col in ()" and the proc throws, so the viewer got an error.
    Action Request recipients usually have no Dynamic Reports access at all (and completed Dynamic
    Report tasks hit the same thing for people without the type).

    In the mailbox, being on the message (sender, recipient, or a colleague the item's task is
    shared with, the same rule as MBX_GetDRItemReport) is what grants the report, so this proc
    checks that and then returns the report's rows with CMS's own row-visibility rule
    (AccessTreeDown on the row creator's company), without the report-type filter.
    The raw Col1..Col100 + headers come back; DRViewController names the columns from headers
    the same way NEO_GetDynamicReportsALL2 does.

    Read-only. CMS's NEO_GetDynamicReportsALL2 is not changed.
    After running: refresh QA_/PROD_Stored_Procedures.sql (MBX_GetDRItemReportRows).
*/
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRItemReportRows]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @ReportID NVARCHAR(50)

	SELECT @ReportID = dbo.MBX_ItemReportID(mi.MessageItemID)   -- sql/045
	FROM MBX_MessageItem mi
	JOIN MBX_Message m ON m.MessageID = mi.MessageID
	WHERE mi.MessageItemID = @MessageItemID
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID)
		-- sql/026: or a colleague the item's task is shared with
		OR EXISTS (SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = mi.MessageItemID
			AND (dbo.MBX_CanViewTask(t.TaskID, @UID) = 1 OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)))

	IF @ReportID IS NULL RETURN

	DECLARE @MyCID INT = dbo.mycid(@UID)

	SELECT ROW_NUMBER() OVER (ORDER BY c.Company, dr.id) AS xxxIX,
		dr.id AS xxxID, ccid.CID AS xCID, c.Company AS Company_Loaded_By,
		CASE WHEN dr.Inactive = 1 THEN 'Inactive' ELSE 'Active' END AS Status,
		CAST(CASE WHEN ccid.CID = @MyCID THEN 1 ELSE 0 END AS BIT) AS xxxIsMine,
		dr.ReportID AS DR_ReportID, dr.Type AS DR_ReportType, dr.Name AS DR_ReportName, dr.headers AS hdrs,
		ISNULL(drd.Attachments, 0) AS Attachments,
		Col1,Col2,Col3,Col4,Col5,Col6,Col7,Col8,Col9,Col10,Col11,Col12,Col13,Col14,Col15,Col16,Col17,Col18,Col19,Col20,
		Col21,Col22,Col23,Col24,Col25,Col26,Col27,Col28,Col29,Col30,Col31,Col32,Col33,Col34,Col35,Col36,Col37,Col38,Col39,Col40,
		Col41,Col42,Col43,Col44,Col45,Col46,Col47,Col48,Col49,Col50,Col51,Col52,Col53,Col54,Col55,Col56,Col57,Col58,Col59,Col60,
		Col61,Col62,Col63,Col64,Col65,Col66,Col67,Col68,Col69,Col70,Col71,Col72,Col73,Col74,Col75,Col76,Col77,Col78,Col79,Col80,
		Col81,Col82,Col83,Col84,Col85,Col86,Col87,Col88,Col89,Col90,Col91,Col92,Col93,Col94,Col95,Col96,Col97,Col98,Col99,Col100
	FROM NEO_DynamicReports dr
	CROSS APPLY (SELECT dbo.mycid(dr.CreatedBy) AS CID) ccid
	JOIN Companies c ON c.CID = ccid.CID
	JOIN AccessTreeDown(@UID) atd ON atd.CID = ccid.CID AND atd.Down = 1
	LEFT JOIN (SELECT DR_ID, COUNT(FID) AS Attachments FROM NEO_DynamicReportDocs WHERE active = 1 GROUP BY DR_ID) drd ON drd.DR_ID = dr.id
	WHERE dr.ReportID = @ReportID
	AND dr.active = 1
	ORDER BY xxxIX
END
GO

-- Test (QA): pick an Action Request item from diag_045 step 2 and a recipient UID
-- exec MBX_GetDRItemReportRows @UID = <recipient uid>, @MessageItemID = <item id>
