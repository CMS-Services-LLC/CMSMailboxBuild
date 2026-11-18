/*  045 - Action Request on a dynamic report opens the mailbox's Dynamic Report viewer  (2026-11-18)

    An Action Request is a form application record (an IAFormRecord message item) linked to a
    whole dynamic report by NEO_IAFormSystemLinks (CMS sql/ar_001, ElemType 'Dynamic Report',
    ElemID = ReportID). The link at the top of the record now opens the mailbox's own report
    viewer (DRViewController) for that same message item, so these two gates also accept an
    IAFormRecord item and resolve the report its record points at.

    Who passes is unchanged: the message's sender, a recipient, or a colleague the item's task
    is shared with. Rows still need CMS's report-visibility rule (AccessTreeDown) and IsMine to
    edit. MBX_GetDRShareCompanies needs no change (it only reads the item's participants).

    Additive: DRTask / DynamicReport items resolve exactly as before.
    Needs NEO_IAFormSystemLinks (CMS sql/ar_001) on the same database.
    After running: refresh QA_/PROD_Stored_Procedures.sql (MBX_GetDRItemReport, MBX_GetDRRowAccess)
    and QA_/PROD_Scalar_Functions.sql (MBX_ItemReportID).
*/

-- The report a message item opens, or NULL. Access is NOT checked here.
CREATE OR ALTER FUNCTION [dbo].[MBX_ItemReportID] (@MessageItemID INT)
RETURNS NVARCHAR(50)
AS
BEGIN
	DECLARE @ItemType NVARCHAR(50), @ItemID NVARCHAR(100), @ReportID NVARCHAR(50)

	SELECT @ItemType = ItemType, @ItemID = ItemID FROM MBX_MessageItem WHERE MessageItemID = @MessageItemID

	IF @ItemType IN ('DRTask', 'DynamicReport') AND @ItemID <> '0'
		SET @ReportID = @ItemID
	ELSE IF @ItemType = 'IAFormRecord' AND TRY_CAST(@ItemID AS INT) > 0
		SELECT TOP 1 @ReportID = sl.ElemID
		FROM NEO_IAFormRecords fr
		JOIN NEO_IAFormSystemLinks sl ON sl.RecordID = fr.RecordID AND sl.active = 1 AND sl.ElemType = 'Dynamic Report'
		WHERE fr.id = TRY_CAST(@ItemID AS INT)
		ORDER BY sl.id DESC

	RETURN @ReportID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRItemReport]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @ReportID NVARCHAR(50) = dbo.MBX_ItemReportID(@MessageItemID)   -- sql/045
	IF @ReportID IS NULL RETURN

	SELECT @ReportID AS ReportID
	FROM MBX_MessageItem mi
	JOIN MBX_Message m ON m.MessageID = mi.MessageID
	WHERE mi.MessageItemID = @MessageItemID
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID)
		-- sql/026: or a colleague the item's task is shared with
		OR EXISTS (SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = mi.MessageItemID
			AND (dbo.MBX_CanViewTask(t.TaskID, @UID) = 1 OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)))
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRRowAccess]
	@UID INT,
	@MessageItemID INT,
	@DRID INT
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

	SELECT dr.id AS DRID, dr.ReportID,
		-- A read-only share never edits rows (sql/026).
		CAST(CASE WHEN dbo.mycid(dr.CreatedBy) = dbo.mycid(@UID)
			AND NOT EXISTS (
				SELECT 1 FROM MBX_Task t
				WHERE t.MessageItemID = @MessageItemID
				AND dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 0 AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 0
				AND (dbo.MBX_TaskShareAccess(t.TaskID, @UID) = 'read' OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) = 'read'))
			THEN 1 ELSE 0 END AS BIT) AS IsMine
	FROM NEO_DynamicReports dr
	JOIN AccessTreeDown(@UID) atd ON atd.CID = dbo.mycid(dr.CreatedBy) AND atd.Down = 1
	WHERE dr.id = @DRID
	AND dr.ReportID = @ReportID
	AND dr.active = 1
END
GO

-- Test (QA): an Action Request item on a report resolves; a DR item still resolves.
-- select mi.MessageItemID, mi.ItemType, mi.ItemID, dbo.MBX_ItemReportID(mi.MessageItemID) ReportID
-- from MBX_MessageItem mi where mi.ItemType in ('IAFormRecord','DynamicReport','DRTask') and dbo.MBX_ItemReportID(mi.MessageItemID) is not null
