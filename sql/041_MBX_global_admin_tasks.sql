/*
	041 (2026-11-16, John): Global Administrators manage their company's tasks, and an exam task
	can be marked Completed at any time. Requires 039 + 040 (both on QA and PROD; every object
	replaced here matched the QA and PROD dumps of 2026-11-13 before this was written).

	1. Global Administrator access ("Full manage", "company signed in as")
	   A user with 'Global Administrator' in their User Groups (on their management account, the
	   way CMS's ftnUserSecurity reads it, so a toggled account inherits it) gets 'manage' access
	   to every task on the side of their CURRENT company (dbo.mycid):
	     assigner side  the task was assigned by someone in my company   -> open, Mark Completed,
	                                                                         Remind, Cancel, Share
	     assignee side  the task was assigned to someone in my company   -> open and work it, Share
	   It works through the two share-access functions every gate already uses, so the mailbox
	   (message, exam viewer, form/DR tasks, handoff) and CMS's Assigned Tasks follow without other
	   changes. It is NOT a share: no MBX_TaskShare rows, nothing in the mailbox's Shared folder,
	   and CMS's Shared with Me lists only real shares.

	   - MBX_IsGlobalAdmin(@UID): new.
	   - MBX_IsTaskSideAdmin(@TaskID, @UID, @Side): new. GA + that side's company = my company.
	   - MBX_TaskShareRowAccess / MBX_AssigneeShareRowAccess: new; 028's share-only versions.
	   - MBX_TaskShareAccess / MBX_AssigneeShareAccess: 'manage' for a side admin, else the share.
	   - MBX_IsSharedOnMessage: no longer requires a share row (the handoff into the mailbox).
	   - MBX_GetMessage: 032 + AdminAccess (1 = the caller sees it only as a Global Administrator).
	   - MBX_GetAssignedTasks: 039 + MyAccess / AssigneeAccess 'admin', AdminAssigner, AdminAssignee.
	     Shared with Me scopes ('shared', 'receivedshared') read real shares only.
	   - MBX_GetTaskShares / MBX_SetTaskShare / MBX_TaskShareCandidates (040): owner OR side admin.

	2. Exam tasks: Mark Completed at any time
	   - MBX_ReviewTask: an exam task can be completed by its assigner (or a manage share, or a GA)
	     whether or not the assignee started it in the mailbox (Open or Pending Review), but NOT
	     while the exam has unreleased changes for the examined company (MBX_TaskUnreleased,
	     err 'unreleased'). ResultID is set to the ExamID if it was never started, so the status
	     reads Completed. Other task types are unchanged.

	Idempotent; safe to run more than once.
	Rollback: re-run, in order, the matching sections of 014 (MBX_ReviewTask), 028
	(MBX_TaskShareAccess, MBX_AssigneeShareAccess, MBX_IsSharedOnMessage, MBX_GetTaskShares,
	MBX_SetTaskShare), 032 (MBX_GetMessage), 039 (MBX_GetAssignedTasks), 040
	(MBX_TaskShareCandidates). The new functions can stay.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1 when @UID's management account (itself, for someone without toggle accounts) has
-- 'Global Administrator' in its User Groups: the same join CMS's ftnUserSecurity uses.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsGlobalAdmin](@UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (
		SELECT 1
		FROM NEO_SecurityGroupAssignments sga
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.GroupID AND sg.Action = 'Global Administrator'
		JOIN Users u ON u.UID = @UID AND u.Active = 1
		WHERE sga.uid = @UID AND sga.active = 1
	) RETURN 1
	IF EXISTS (
		SELECT 1
		FROM initBaseMGTUsersByUIDx(@UID) b
		JOIN NEO_SecurityGroupAssignments sga ON sga.uid = b.MGTUID AND sga.active = 1
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.GroupID AND sg.Action = 'Global Administrator'
		WHERE b.UID = @UID
	) RETURN 1
	RETURN 0
END
GO

-- 1 when @UID is a Global Administrator signed in as the company on @Side of the task:
-- 'assigner' = the assigner's company, 'assignee' = the assignee's company.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskSideAdmin](@TaskID INT, @UID INT, @Side VARCHAR(10))
RETURNS BIT
AS
BEGIN
	DECLARE @SideUID INT
	SELECT @SideUID = CASE WHEN @Side = 'assignee' THEN AssignedToUID ELSE AssignedByUID END
	FROM MBX_Task WHERE TaskID = @TaskID
	IF @SideUID IS NULL RETURN 0
	-- cheap company test first; the GA lookup only when it matches
	IF dbo.mycid(@SideUID) <> dbo.mycid(@UID) RETURN 0
	IF dbo.MBX_IsGlobalAdmin(@UID) = 1 RETURN 1
	RETURN 0
END
GO

-- 028's MBX_TaskShareAccess: the caller's real share on the assigner side ('manage' wins), or NULL.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareRowAccess](@TaskID INT, @UID INT)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE @a VARCHAR(10)
	SELECT TOP 1 @a = sh.Access
	FROM MBX_TaskShare sh
	JOIN Users su ON su.UID = sh.UID AND su.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE sh.TaskID = @TaskID AND sh.Active = 1 AND sh.Side = 'assigner'
	AND (sh.UID = @UID OR su.Email = me.Email)
	ORDER BY CASE sh.Access WHEN 'manage' THEN 0 ELSE 1 END
	RETURN @a
END
GO

-- 028's MBX_AssigneeShareAccess: the caller's real share from the assignee ('manage' wins), or NULL.
CREATE OR ALTER FUNCTION [dbo].[MBX_AssigneeShareRowAccess](@TaskID INT, @UID INT)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE @a VARCHAR(10)
	SELECT TOP 1 @a = sh.Access
	FROM MBX_TaskShare sh
	JOIN Users su ON su.UID = sh.UID AND su.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE sh.TaskID = @TaskID AND sh.Active = 1 AND sh.Side = 'assignee'
	AND (sh.UID = @UID OR su.Email = me.Email)
	ORDER BY CASE sh.Access WHEN 'manage' THEN 0 ELSE 1 END
	RETURN @a
END
GO

-- Assigner-side access: a real share, or 'manage' for a Global Administrator of the assigner's company.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareAccess](@TaskID INT, @UID INT)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE @a VARCHAR(10) = dbo.MBX_TaskShareRowAccess(@TaskID, @UID)
	IF @a = 'manage' RETURN @a
	IF dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, 'assigner') = 1 RETURN 'manage'   -- sql/041
	RETURN @a
END
GO

-- Assignee-side access: a real share, or 'manage' for a Global Administrator of the assignee's company.
CREATE OR ALTER FUNCTION [dbo].[MBX_AssigneeShareAccess](@TaskID INT, @UID INT)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE @a VARCHAR(10) = dbo.MBX_AssigneeShareRowAccess(@TaskID, @UID)
	IF @a = 'manage' RETURN @a
	IF dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, 'assignee') = 1 RETURN 'manage'   -- sql/041
	RETURN @a
END
GO

-- A task on this message is shared with the caller, by either side, or (sql/041) the caller is a
-- Global Administrator of one side's company: their way into the message (handoff, thread).
CREATE OR ALTER FUNCTION [dbo].[MBX_IsSharedOnMessage](@MessageID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (
		SELECT 1
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID
		AND (dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	) RETURN 1
	RETURN 0
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetMessage]
	@UID INT,
	@MessageID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @IsRecipient BIT = 0, @IsArchived BIT = 0

	SELECT @IsRecipient = 1, @IsArchived = IsArchived
	FROM MBX_Recipient
	WHERE MessageID = @MessageID AND ToUID = @UID

	-- Recipient OR author. Deliberately returns nothing distinguishable from "message
	-- doesn't exist" for anyone else - never confirm existence of a message the
	-- caller has no relationship to.
	DECLARE @IsAuthor BIT = CASE WHEN EXISTS (SELECT 1 FROM MBX_Message WHERE MessageID = @MessageID AND FromUID = @UID) THEN 1 ELSE 0 END
	-- sql/026: or a colleague a task on this message is shared with. They see it as its
	-- sender does in Sent; SharedAccess tells the page how it was shared.
	DECLARE @SharedAccess VARCHAR(10) = NULL
	IF @IsRecipient = 0 AND @IsAuthor = 0
		SELECT TOP 1 @SharedAccess = dbo.MBX_TaskShareAccess(t.TaskID, @UID)
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL
		ORDER BY CASE dbo.MBX_TaskShareAccess(t.TaskID, @UID) WHEN 'manage' THEN 0 ELSE 1 END

	-- sql/028: or a colleague the assignee shared a task on this message with. They see the
	-- shared task's item as a recipient would, nothing else (no reply, no archive).
	DECLARE @AssigneeSharedAccess VARCHAR(10) = NULL
	IF @IsRecipient = 0 AND @IsAuthor = 0 AND @SharedAccess IS NULL
		SELECT TOP 1 @AssigneeSharedAccess = dbo.MBX_AssigneeShareAccess(t.TaskID, @UID)
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL
		ORDER BY CASE dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) WHEN 'manage' THEN 0 ELSE 1 END

	IF @IsRecipient = 0 AND @IsAuthor = 0 AND @SharedAccess IS NULL AND @AssigneeSharedAccess IS NULL
	BEGIN
		RETURN
	END

	-- sql/041: the caller is here only as a Global Administrator (no real share on this message),
	-- so the page labels it that way instead of "Shared with you by ...".
	DECLARE @AdminAccess BIT = 0
	IF @IsRecipient = 0 AND @IsAuthor = 0 AND NOT EXISTS (
		SELECT 1
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		WHERE mi.MessageID = @MessageID
		AND (dbo.MBX_TaskShareRowAccess(t.TaskID, @UID) IS NOT NULL OR dbo.MBX_AssigneeShareRowAccess(t.TaskID, @UID) IS NOT NULL)
	)
		SET @AdminAccess = 1

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames,
		@SharedAccess AS SharedAccess,
		@AssigneeSharedAccess AS AssigneeSharedAccess,
		@AdminAccess AS AdminAccess	-- sql/041
	FROM MBX_Message m
	JOIN Users u ON u.UID = m.FromUID
	JOIN Companies c ON c.CID = m.FromCID
	WHERE m.MessageID = @MessageID AND m.IsDeleted = 0

	SELECT mi.MessageItemID, mi.ItemType, mi.ItemID, mi.ItemLabel, mi.FormID,
		t.TaskID, t.TaskType,
		dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
		CASE
			WHEN d.Done = 0 THEN NULL
			WHEN t.RequiresReview = 1 THEN t.DTReviewed
			WHEN t.TaskType = 'FormApplication' THEN rel.DTReleased
			ELSE t.DTCompleted
		END AS TaskCompleted,
		t.DueDate,
		t.RequiresReview,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssignee(t.TaskID, @UID) ELSE 0 END AS IsMyTask,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) ELSE 0 END AS IsAssigneeOwner,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) ELSE 0 END AS IsAssigner,
		ot.OriginTaskType,
		ot.OriginTaskStatus,
		ot.OriginDueDate,
		CASE WHEN ot.OriginTaskStatus = 'Pending Review' AND ot.CallerIsAssigner = 1 THEN ot.OriginTaskItemID END AS ReviewTaskItemID,
		ex.ExamName,
		ex.ExamCompany,
		ex.ExamMgtCompany
	FROM MBX_MessageItem mi
	LEFT JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	OUTER APPLY (SELECT dbo.MBX_TaskIsDone(t.TaskID) AS Done) d
	OUTER APPLY (
		SELECT TOP 1 fr.DTReleased
		FROM NEO_IAFormRecords xfr
		JOIN NEO_IAFormRecords fr ON fr.RecordID = xfr.RecordID AND fr.active = 1
		WHERE t.TaskType = 'FormApplication' AND xfr.ID = TRY_CAST(t.ResultID AS INT)
	) rel
	-- A reply's copy of a task's record/report/exam: the task it came from, if the
	-- caller is that task's assignee or assigner.
	OUTER APPLY (
		SELECT TOP 1
			rt.MessageItemID AS OriginTaskItemID,
			rt.TaskType AS OriginTaskType,
			dbo.MBX_TaskStatusText(rt.TaskID) AS OriginTaskStatus,
			rt.DueDate AS OriginDueDate,
			dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) AS CallerIsAssigner
		FROM MBX_Task rt
		WHERE t.TaskID IS NULL
		AND mi.ItemID <> '0'
		AND (
			(mi.ItemType = 'ExamRef' AND rt.TaskType = 'Exam' AND rt.MessageItemID = TRY_CAST(mi.ItemID AS INT))
			OR (rt.ResultID = mi.ItemID
				AND rt.TaskType = CASE mi.ItemType WHEN 'IAFormRecord' THEN 'FormApplication' WHEN 'DynamicReport' THEN 'DynamicReport' END)
		)
		AND (dbo.MBX_IsTaskAssigner(rt.TaskID, @UID) = 1 OR dbo.MBX_IsTaskAssignee(rt.TaskID, @UID) = 1)
		ORDER BY rt.TaskID DESC
	) ot
	-- sql/032: an exam item's name and companies, for the one-line summary.
	OUTER APPLY (
		SELECT TOP 1
			n.Name AS ExamName,
			tc.Company AS ExamCompany,
			oc.Company AS ExamMgtCompany
		FROM MBX_Task et
		JOIN a_aMgtExamNames n ON n.ExamID = et.ExamID AND n.Active = 1
		LEFT JOIN Companies tc ON tc.CID = et.ExamCID
		LEFT JOIN Companies oc ON oc.CID = n.OwnerCID
		WHERE mi.ItemType IN ('ExamTask', 'ExamRef')
		AND et.TaskType = 'Exam'
		AND et.MessageItemID = CASE mi.ItemType WHEN 'ExamTask' THEN mi.MessageItemID ELSE TRY_CAST(mi.ItemID AS INT) END
	) ex
	WHERE mi.MessageID = @MessageID
	AND (@AssigneeSharedAccess IS NULL OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	ORDER BY mi.MessageItemID
END
GO

-- Mark as Completed. 014's checks, plus (sql/041) an exam task completes whenever its assigner
-- says so (Open or Pending Review), unless the exam has unreleased changes.
CREATE OR ALTER PROCEDURE [dbo].[MBX_ReviewTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT, @TaskType VARCHAR(20), @Status VARCHAR(20)

	SELECT @TaskID = TaskID, @TaskType = TaskType, @Status = Status
	FROM MBX_Task
	WHERE MessageItemID = @MessageItemID
	AND RequiresReview = 1
	AND DTReviewed IS NULL

	IF @TaskID IS NULL OR dbo.MBX_IsTaskAssigner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'no task awaiting your review on this item' AS err
		RETURN
	END

	IF @TaskType = 'Exam'
	BEGIN
		IF @Status = 'Cancelled'
		BEGIN
			SELECT 'cancelled' AS err
			RETURN
		END
		IF dbo.MBX_TaskUnreleased(@TaskID) = 1
		BEGIN
			SELECT 'unreleased' AS err
			RETURN
		END
		-- never started in the mailbox: mark it started too, so the status reads Completed
		UPDATE MBX_Task SET ResultID = ISNULL(ResultID, ExamID), ReviewedByUID = @UID, DTReviewed = getdate()
		WHERE TaskID = @TaskID
		SELECT @TaskID AS TaskID
		RETURN
	END

	IF dbo.MBX_TaskIsDone(@TaskID) = 0
	BEGIN
		SELECT 'the assignee has not finished this task yet' AS err
		RETURN
	END

	UPDATE MBX_Task SET ReviewedByUID = @UID, DTReviewed = getdate() WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID
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
	DECLARE @IsGA BIT = dbo.MBX_IsGlobalAdmin(@UID)   -- sql/041, looked up once

	SELECT y.*,
		CAST(CASE WHEN y.DueDate < CAST(getdate() AS date) AND y.TaskStatus NOT IN ('Completed', 'Cancelled', 'Pending Review') THEN 1 ELSE 0 END AS BIT) AS IsOverdue
	FROM (
		SELECT x.TaskID, x.MessageID, x.MessageItemID, x.Subject, x.TaskType, x.TaskName,
			x.AssignedByName, x.AssignedToName, x.AssignedToCompany,
			x.DTCreated, x.DueDate, x.TaskStatus,
			x.RequiresReview, x.DTReviewed, x.DTCompleted, x.DTCancelled,
			x.ReminderCount, x.DTLastReminder,
			-- IsMine = owner, a Manage share, or (sql/041) Global Administrator of the assigner's company
			CAST(CASE WHEN x.IsOwner = 1 OR x.RowShare = 'manage' OR x.AdminAssigner = 1 THEN 1 ELSE 0 END AS BIT) AS IsMine,
			x.IsOwner,
			CASE WHEN x.IsOwner = 1 THEN 'owner' WHEN x.RowShare = 'manage' THEN 'manage' WHEN x.AdminAssigner = 1 THEN 'admin' ELSE x.RowShare END AS MyAccess,
			x.ShareCount,
			x.AssignedByCompany,
			x.IsAssigneeOwner,
			CAST(CASE WHEN x.IsAssigneeOwner = 1 OR x.AssigneeRowShare = 'manage' OR x.AdminAssignee = 1 THEN 1 ELSE 0 END AS BIT) AS CanWork,
			CASE WHEN x.IsAssigneeOwner = 1 THEN 'owner' WHEN x.AssigneeRowShare = 'manage' THEN 'manage' WHEN x.AdminAssignee = 1 THEN 'admin' ELSE x.AssigneeRowShare END AS AssigneeAccess,
			x.AssigneeShareCount,
			x.Unreleased,
			x.AdminAssigner,	-- sql/041
			x.AdminAssignee		-- sql/041
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
				dbo.MBX_IsTaskOwner(t.TaskID, @UID) AS IsOwner,
				dbo.MBX_TaskShareRowAccess(t.TaskID, @UID) AS RowShare,
				(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assigner') AS ShareCount,
				abc.Company AS AssignedByCompany,
				dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) AS IsAssigneeOwner,
				dbo.MBX_AssigneeShareRowAccess(t.TaskID, @UID) AS AssigneeRowShare,
				(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assignee') AS AssigneeShareCount,
				dbo.MBX_TaskUnreleased(t.TaskID) AS Unreleased,	-- sql/039
				CAST(CASE WHEN @IsGA = 1 AND dbo.mycid(t.AssignedByUID) = @MyCID THEN 1 ELSE 0 END AS BIT) AS AdminAssigner,
				CAST(CASE WHEN @IsGA = 1 AND dbo.mycid(t.AssignedToUID) = @MyCID THEN 1 ELSE 0 END AS BIT) AS AdminAssignee
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
				-- sql/041: Shared with Me = real shares only (a Global Administrator's access is not a share)
				OR (@Scope = 'shared' AND dbo.mycid(t.AssignedByUID) = @MyCID
					AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 0 AND dbo.MBX_TaskShareRowAccess(t.TaskID, @UID) IS NOT NULL)
				-- sql/028, CMS's Assigned to Me
				OR (@Scope = 'received' AND dbo.mycid(t.AssignedToUID) = @MyCID AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 1)
				OR (@Scope = 'receivedshared' AND dbo.mycid(t.AssignedToUID) = @MyCID
					AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 0 AND dbo.MBX_AssigneeShareRowAccess(t.TaskID, @UID) IS NOT NULL)
			)
		) x
	) y
	ORDER BY y.DTCreated DESC, y.TaskID
END
GO

-- 028's version; the task's owner on that side, or (sql/041) a Global Administrator of that side's company.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskShares]
	@UID INT,
	@TaskID INT,
	@Side VARCHAR(10) = 'assigner'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF (CASE WHEN @Side = 'assignee' THEN dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) ELSE dbo.MBX_IsTaskOwner(@TaskID, @UID) END) = 0
		AND dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, CASE WHEN @Side = 'assignee' THEN 'assignee' ELSE 'assigner' END) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	SELECT sh.UID, u.Fname + ' ' + u.Lname AS Name, u.Email, c.Company, sh.Access, sh.DTGranted
	FROM MBX_TaskShare sh
	JOIN Users u ON u.UID = sh.UID
	LEFT JOIN Companies c ON c.CID = dbo.mycid(sh.UID)
	WHERE sh.TaskID = @TaskID AND sh.Active = 1 AND sh.Side = ISNULL(NULLIF(@Side, ''), 'assigner')
	ORDER BY u.Lname, u.Fname
END
GO

-- 028's version; the task's owner on that side, or (sql/041) a Global Administrator of that side's company.
CREATE OR ALTER PROCEDURE [dbo].[MBX_SetTaskShare]
	@UID INT,
	@TaskID INT,
	@ShareUID INT,
	@Access VARCHAR(10),
	@Side VARCHAR(10) = 'assigner'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SET @Side = CASE WHEN @Side = 'assignee' THEN 'assignee' ELSE 'assigner' END

	IF (CASE WHEN @Side = 'assignee' THEN dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) ELSE dbo.MBX_IsTaskOwner(@TaskID, @UID) END) = 0
		AND dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, @Side) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	IF @Access = 'none'
	BEGIN
		UPDATE MBX_TaskShare SET Active = 0, DTRevoked = getdate()
		WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1 AND Side = @Side
		SELECT @TaskID AS TaskID
		RETURN
	END

	IF @Access NOT IN ('manage', 'read')
	BEGIN
		SELECT 'bad_access' AS err
		RETURN
	END

	IF NOT EXISTS (SELECT 1 FROM dbo.MBX_TaskShareCandidates(@UID, @TaskID, @Side) WHERE UID = @ShareUID)
	BEGIN
		SELECT 'not_allowed' AS err
		RETURN
	END

	IF EXISTS (SELECT 1 FROM MBX_TaskShare WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1 AND Side = @Side)
		UPDATE MBX_TaskShare SET Access = @Access, GrantedByUID = @UID, DTGranted = getdate()
		WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1 AND Side = @Side
	ELSE
		INSERT INTO MBX_TaskShare (TaskID, UID, Access, GrantedByUID, Side)
		VALUES (@TaskID, @ShareUID, @Access, @UID, @Side)

	SELECT @TaskID AS TaskID
END
GO

-- 040's version; only the first two lines changed (owner OR, sql/041, Global Administrator of that side's company).
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareCandidates](@UID INT, @TaskID INT, @Side VARCHAR(10))
RETURNS @r TABLE (UID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
AS
BEGIN
	IF @Side = 'assignee' AND dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) = 0 AND dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, 'assignee') = 0 RETURN
	IF @Side <> 'assignee' AND dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0 AND dbo.MBX_IsTaskSideAdmin(@TaskID, @UID, 'assigner') = 0 RETURN

	DECLARE @TaskType VARCHAR(20), @FormID VARCHAR(100), @ByUID INT, @ToUID INT
	SELECT @TaskType = TaskType, @FormID = FormID, @ByUID = AssignedByUID, @ToUID = AssignedToUID
	FROM MBX_Task WHERE TaskID = @TaskID

	DECLARE @MyCID INT = dbo.mycid(@UID)

	-- people with an account in my current company: UID = that account, MgtUID = where their
	-- security lives (the same account for someone without toggle accounts)
	DECLARE @co TABLE (UID INT, MgtUID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
	INSERT INTO @co
	SELECT DISTINCT u.UID, u.MgtUID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN Users a ON a.UID = u.UID AND a.Active = 1 AND a.CID = @MyCID
	WHERE u.CID = @MyCID

	DECLARE @ok TABLE (MgtUID INT)

	INSERT INTO @ok
	SELECT c.MgtUID
	FROM @co c
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = c.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Global Administrator'

	IF @TaskType = 'Exam'
		INSERT INTO @ok
		SELECT c.MgtUID
		FROM @co c
		JOIN NEO_SecurityGroupAssignments sga ON sga.uid = c.MgtUID AND sga.active = 1
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Exams'
	ELSE IF @TaskType = 'DynamicReport'
		INSERT INTO @ok
		SELECT c.MgtUID
		FROM @co c
		JOIN NEO_SecurityGroupAssignments sga ON sga.uid = c.MgtUID AND sga.active = 1
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Dynamic Reports'
	ELSE IF @TaskType = 'FormApplication'
	BEGIN
		DECLARE @groups TABLE (GroupType VARCHAR(100), GroupID VARCHAR(100))
		INSERT INTO @groups
		SELECT GroupType, GroupID FROM NEO_IAFormAccess WHERE formid = @FormID AND active = 1

		IF EXISTS (SELECT 1 FROM @groups WHERE GroupType = 'Team')
			INSERT INTO @ok
			SELECT c.MgtUID
			FROM @co c
			JOIN NEO_SecurityTeamAssignments sta ON sta.uid = c.MgtUID AND sta.active = 1
			JOIN NEO_SecurityTeamGroups stg ON stg.GroupID = sta.GroupID AND stg.active = 1
			JOIN @groups g ON g.GroupType = 'Team' AND g.GroupID = stg.GroupID
			LEFT JOIN NEO_SecurityTeamCompanyGroups stcg ON stcg.TeamID = g.GroupID AND stcg.active = 1
			LEFT JOIN Neo_CompanyGroups cg ON cg.groupid = stcg.CompanyGroupID AND cg.active = 1
			LEFT JOIN Neo_CompanyGroupAssignments cga ON cga.GroupID = cg.GroupID AND cga.active = 1 AND cga.xcid = @MyCID
			WHERE stcg.id IS NULL OR cga.id IS NOT NULL
		ELSE
			INSERT INTO @ok
			SELECT c.MgtUID
			FROM @co c
			JOIN NEO_SecurityGroupAssignments sga ON sga.uid = c.MgtUID AND sga.active = 1
			JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action = 'Form Applications'
	END

	-- me, the assigner and the assignee, by email (each may have several accounts)
	DECLARE @skip TABLE (Email VARCHAR(300))
	INSERT INTO @skip SELECT Email FROM Users WHERE UID IN (@UID, @ByUID, @ToUID) AND Email IS NOT NULL

	INSERT INTO @r
	SELECT DISTINCT c.UID, c.Name, c.Email, c.Company
	FROM @co c
	WHERE c.MgtUID IN (SELECT MgtUID FROM @ok)
	AND c.UID NOT IN (@UID, @ByUID, @ToUID)
	AND c.Email NOT IN (SELECT Email FROM @skip)

	RETURN
END
GO

SELECT '041 done' AS Result,
	OBJECT_ID('dbo.MBX_IsGlobalAdmin') AS IsGlobalAdmin,
	OBJECT_ID('dbo.MBX_IsTaskSideAdmin') AS IsTaskSideAdmin,
	OBJECT_ID('dbo.MBX_TaskShareRowAccess') AS TaskShareRowAccess,
	OBJECT_ID('dbo.MBX_AssigneeShareRowAccess') AS AssigneeShareRowAccess

-- Checks (read-only), with a Global Administrator's UID signed in as a company that has tasks:
-- select dbo.MBX_IsGlobalAdmin(<uid>)
-- exec MBX_GetAssignedTasks <uid>, 'company'   -- MyAccess / AssigneeAccess 'admin' on colleagues' tasks
-- exec MBX_GetAssignedTasks <uid>, 'shared'    -- unchanged: real shares only
