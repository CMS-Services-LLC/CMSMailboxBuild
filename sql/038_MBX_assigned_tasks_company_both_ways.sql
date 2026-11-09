/*
	CMS Assigned Tasks > Company shows tasks both ways. Requires 037.

	- John (2026-11-09): the Company section should show tasks assigned BY anyone in the company
	  you're signed in as AND tasks assigned TO anyone in it (037 showed only "by").
	- MBX_GetAssignedTasks: same as 037 except the 'company' scope:
	    company   dbo.mycid(AssignedByUID) = @MyCID  OR  dbo.mycid(AssignedToUID) = @MyCID
	  Every other scope is unchanged (still limited to the signed-in company, 037).
	- Also changes the dashboard's Open Tasks "Company" count, which uses the same scope.

	Idempotent; safe to run more than once.
	Refresh in SQL_Repos afterwards: QA_Stored_Procedures.sql (and PROD_Stored_Procedures.sql when run there).
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
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
			(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assignee') AS AssigneeShareCount
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
