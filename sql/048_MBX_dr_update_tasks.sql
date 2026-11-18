/*  048 - "Update an existing Dynamic Report" tasks  (2026-11-18)

    Assign Task -> Dynamic Report -> Update an existing report: the assigner picks a report they
    can see and writes the instructions in the message. The assignee gets the report itself on
    the message (an MBX_MessageItem of ItemType 'DynamicReport', ItemID = ReportID, so the
    mailbox's report viewer opens it through MBX_ItemReportID / MBX_GetDRItemReportRows, sql/045
    and 047), edits / adds rows there (only the report's own company can: NEO_DynamicRecordUpdate),
    and clicks Mark as Done. With "Require my review" it then shows Pending Review until the
    assigner marks it Completed (MBX_ReviewTask, unchanged).

    1. CK_MBX_Task_TaskType also allows 'DRUpdate'.
    2. MBX_TaskIsDone: a DRUpdate task is done once its Status is Completed (same as DynamicReport).
    3. MBX_GetAssignableReports: reports the caller can see (CMS's AccessTreeDown rule on the
       report's company), one row per ReportID.
    4. MBX_GetDRUpdateTaskCandidates: who can work one of them = people the caller can assign to
       (neousers, deduped to the MGT account) whose company owns the report, since only that
       company can edit its rows. No Dynamic Reports permission needed: the work is done in the
       mailbox (sql/047 needs none).
    5. MBX_CompleteDRUpdateTask: the assignee (or a 'manage' colleague, MBX_IsTaskAssignee) marks
       an open DRUpdate task done.

    Additive: existing task types behave exactly as before.
    After running: refresh QA_/PROD_Stored_Procedures.sql (MBX_GetAssignableReports,
    MBX_GetDRUpdateTaskCandidates, MBX_CompleteDRUpdateTask), QA_/PROD_Scalar_Functions.sql
    (MBX_TaskIsDone) and QA_/PROD_Tables.sql (MBX_Task constraint).
*/

-- 1. task type
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_MBX_Task_TaskType')
	ALTER TABLE [dbo].[MBX_Task] DROP CONSTRAINT [CK_MBX_Task_TaskType]
GO
ALTER TABLE [dbo].[MBX_Task] WITH CHECK ADD CONSTRAINT [CK_MBX_Task_TaskType]
	CHECK (([TaskType]='Exam' OR [TaskType]='DynamicReport' OR [TaskType]='FormApplication' OR [TaskType]='DRUpdate'))
GO

-- 2. done rule (unchanged for the other types)
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskIsDone](@TaskID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @done BIT = 0

	SELECT @done = 1
	FROM MBX_Task t
	WHERE t.TaskID = @TaskID
	AND t.Status <> 'Cancelled'
	AND (
		(t.TaskType IN ('DynamicReport', 'DRUpdate') AND t.Status = 'Completed')   -- sql/048: DRUpdate
		OR (t.TaskType = 'Exam' AND t.ResultID IS NOT NULL)
		OR (t.TaskType = 'FormApplication' AND EXISTS (
			SELECT 1
			FROM NEO_IAFormRecords xfr
			JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
			WHERE xfr.ID = TRY_CAST(t.ResultID AS INT) AND fr.DTReleased IS NOT NULL
		))
	)

	RETURN @done
END
GO

-- 3. reports the caller can pick
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAssignableReports]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	;WITH r AS (
		SELECT dr.ReportID, dr.Name, dr.Type, dbo.mycid(dr.CreatedBy) AS CID, COUNT(*) AS Rows,
			ROW_NUMBER() OVER (PARTITION BY dr.ReportID ORDER BY MIN(dr.id)) AS rn
		FROM NEO_DynamicReports dr
		WHERE dr.active = 1
		GROUP BY dr.ReportID, dr.Name, dr.Type, dbo.mycid(dr.CreatedBy)
	)
	SELECT r.ReportID, r.Name AS ReportName, r.Type AS ReportType, r.CID, c.Company, r.Rows
	FROM r
	JOIN Companies c ON c.CID = r.CID
	JOIN AccessTreeDown(@UID) atd ON atd.CID = r.CID AND atd.Down = 1
	WHERE r.rn = 1
	ORDER BY c.Company, r.Type, r.Name
END
GO

-- 4. who can work a report: people at the report's own company
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRUpdateTaskCandidates]
	@UID INT,
	@ReportID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @OwnerCID INT = (SELECT TOP 1 dbo.mycid(CreatedBy) FROM NEO_DynamicReports WHERE ReportID = @ReportID AND active = 1 ORDER BY id)
	IF @OwnerCID IS NULL RETURN

	-- the caller must be able to see the report (same rule as MBX_GetAssignableReports)
	IF NOT EXISTS (SELECT 1 FROM AccessTreeDown(@UID) atd WHERE atd.CID = @OwnerCID AND atd.Down = 1) RETURN

	SELECT DISTINCT u.MgtUID AS UID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	WHERE u.MgtUID <> @UID
	AND dbo.mycid(u.MgtUID) = @OwnerCID
	ORDER BY u.Name
END
GO

-- 5. Mark as Done
CREATE OR ALTER PROCEDURE [dbo].[MBX_CompleteDRUpdateTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT, @ReportID NVARCHAR(50)

	SELECT @TaskID = t.TaskID, @ReportID = mi.ItemID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'DRUpdate'
	AND t.Status = 'Open'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1   -- sql/028: or a 'manage' colleague

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no open report update task for this item and user' AS err
		RETURN
	END

	UPDATE MBX_Task SET Status = 'Completed', ResultID = @ReportID, DTCompleted = getdate()
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID
END
GO

-- Test (QA):
-- exec MBX_GetAssignableReports @UID = <assigner uid>
-- exec MBX_GetDRUpdateTaskCandidates @UID = <assigner uid>, @ReportID = '<ReportID from above>'
