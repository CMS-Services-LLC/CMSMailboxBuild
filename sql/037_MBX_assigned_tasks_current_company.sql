/*
	CMS Assigned Tasks / Open Tasks / calendar task layer: only the company you're signed in as.
	Requires 021/026/028 (MBX_GetAssignedTasks and the MBX_IsTask* / share functions).

	- Why (John, 2026-11-09): signed in to CMS as another company, Assigned Tasks showed tasks
	  belonging to his other companies. The "is this mine?" functions (MBX_IsTaskOwner,
	  MBX_IsTaskAssigneeOwner, MBX_TaskShareAccess, MBX_AssigneeShareAccess) match ANY account
	  with the same email. That's deliberate for the mailbox (a basic account still sees work
	  given to the person's main account) and those functions are NOT changed here. But CMS
	  signs you in as one company at a time (a separate account per company; switching company
	  = a different UID), so its task lists must be limited to that company.
	- MBX_GetAssignedTasks: same columns and the same email matching as before, plus a company
	  filter per scope (@MyCID = dbo.mycid(@UID), the company you're signed in as):
	    mine            the assigner's company is @MyCID
	    received        the assignee's company is @MyCID
	    shared          (assigner-side share) the assigner's company is @MyCID
	    receivedshared  (assignee-side share) the assignee's company is @MyCID
	    company         assigned by someone in @MyCID only (the old extra "tasks I own by email,
	                    in any company" rule is dropped)
	- Only CMS calls this proc (main/GetAssignedTasks). The mailbox's own access checks are untouched.

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
			(@Scope = 'company' AND dbo.mycid(t.AssignedByUID) = @MyCID)
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
