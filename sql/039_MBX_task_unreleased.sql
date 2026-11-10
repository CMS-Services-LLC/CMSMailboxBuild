/*
	039: "Unreleased" on assigned tasks (2026-11-10, John). Requires 038, and CMS
	SharedSQLWithClaude/FEATURE_ExamReleaseStatus rel_001 (the Pending* columns the exam check reads).

	- MBX_TaskUnreleased(@TaskID) returns 1 when the work the task shared is saved but not released:
	    FormApplication  its record exists (ResultID, set on the first save) and has not been
	                     Saved for Use (NEO_IAFormRecords.DTReleased is null on the active row)
	    Exam             the exam has unreleased changes for the examined company (ExamID + ExamCID), by
	                     either side (FEATURE_ExamReleaseStatus). Only the fact is shown, never the changes.
	    DynamicReport    never (nothing to release)
	- MBX_GetAssignedTasks: 038's version plus a last column Unreleased (bit). CMS's Assigned Tasks screen
	  shows it next to the status, and the Dashboard's Open Tasks box counts open tasks with it set.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_TaskUnreleased](@TaskID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @type VARCHAR(20), @result VARCHAR(100), @examid VARCHAR(100), @examcid INT
	SELECT @type = TaskType, @result = ResultID, @examid = ExamID, @examcid = ExamCID FROM MBX_Task WHERE TaskID = @TaskID

	IF @type = 'FormApplication'
	BEGIN
		IF EXISTS (
			SELECT 1
			FROM NEO_IAFormRecords xfr
			JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.Active = 1
			WHERE xfr.ID = TRY_CAST(@result AS INT) AND fr.DTReleased IS NULL
		) RETURN 1
		RETURN 0
	END

	IF @type = 'Exam' AND @examid IS NOT NULL AND @examcid IS NOT NULL
	BEGIN
		IF EXISTS (SELECT 1 FROM a_aMgtExamAnswers WHERE xCID = @examcid AND PendingExamID = @examid
				AND ((Active = 0 AND PendingCID IS NOT NULL) OR (Active = 1 AND PendingDeleteCID IS NOT NULL)))
			OR EXISTS (SELECT 1 FROM a_aMgtExamScores WHERE xCID = @examcid AND PendingExamID = @examid AND Active = 0 AND PendingCID IS NOT NULL)
			OR EXISTS (SELECT 1 FROM a_aMGTExamDocs WHERE xCID = @examcid AND ExamID = @examid AND PendingCID IS NOT NULL)
			RETURN 1
		RETURN 0
	END

	RETURN 0
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAssignedTasks]
	@UID INT,
	@Scope VARCHAR(20) = 'mine'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	SELECT x.*,
		CAST(CASE WHEN x.DueDate < CAST(getdate() AS date) AND x.TaskStatus NOT IN ('Completed', 'Cancelled', 'Pending Review') THEN 1 ELSE 0 END AS BIT) AS IsOverdue
	FROM (
		SELECT t.TaskID, mi.MessageID, t.MessageItemID, m.Subject,
			t.TaskType, mi.ItemLabel AS TaskName,
			ab.Fname + ' ' + ab.Lname AS AssignedByName,
			at.Fname + ' ' + at.Lname AS AssignedToName,
			atc.Company AS AssignedToCompany,
			t.DTCreated, t.DueDate,
			dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
			t.RequiresReview, t.DTReviewed, t.DTCompleted, t.DTCancelled,
			t.ReminderCount, t.DTLastReminder,
			dbo.MBX_IsTaskAssigner(t.TaskID, @UID) AS IsMine,
			dbo.MBX_IsTaskOwner(t.TaskID, @UID) AS IsOwner,
			CASE WHEN dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 1 THEN 'owner' ELSE dbo.MBX_TaskShareAccess(t.TaskID, @UID) END AS MyAccess,
			(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assigner') AS ShareCount,
			abc.Company AS AssignedByCompany,
			dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) AS IsAssigneeOwner,
			dbo.MBX_IsTaskAssignee(t.TaskID, @UID) AS CanWork,
			CASE WHEN dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 1 THEN 'owner' ELSE dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) END AS AssigneeAccess,
			(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assignee') AS AssigneeShareCount,
			dbo.MBX_TaskUnreleased(t.TaskID) AS Unreleased	-- sql/039
		FROM MBX_Task t
		JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.IsDeleted = 0
		JOIN Users ab ON ab.UID = t.AssignedByUID
		JOIN Users at ON at.UID = t.AssignedToUID
		LEFT JOIN Companies atc ON atc.CID = dbo.mycid(t.AssignedToUID)
		LEFT JOIN Companies abc ON abc.CID = dbo.mycid(t.AssignedByUID)
		WHERE (
			-- sql/037: every scope is limited to the company the caller is signed in as.
			-- sql/038: Company = assigned BY anyone in my company OR TO anyone in my company.
			(@Scope = 'company' AND (dbo.mycid(t.AssignedByUID) = @MyCID OR dbo.mycid(t.AssignedToUID) = @MyCID))
			OR (@Scope = 'mine' AND dbo.mycid(t.AssignedByUID) = @MyCID AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 1)
			OR (@Scope = 'shared' AND dbo.mycid(t.AssignedByUID) = @MyCID
				AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 0 AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL)
			-- sql/028, CMS's Assigned to Me
			OR (@Scope = 'received' AND dbo.mycid(t.AssignedToUID) = @MyCID AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 1)
			OR (@Scope = 'receivedshared' AND dbo.mycid(t.AssignedToUID) = @MyCID
				AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 0 AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
		)
	) x
	ORDER BY x.DTCreated DESC, x.TaskID
END
GO

SELECT '039 done' AS Result, OBJECT_ID('dbo.MBX_TaskUnreleased') AS Fn, OBJECT_ID('dbo.MBX_GetAssignedTasks') AS ProcID
