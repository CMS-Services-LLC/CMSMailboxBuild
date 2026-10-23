/*
	Phase 7: shared task access. The assigner shares a task they assigned with colleagues in
	their own company who hold the task's own permission, with 'manage' or 'read' access.
	Requires 006-025.

	- MBX_TaskShare: one active row per (task, colleague). Only the task's real assigner
	  (MBX_IsTaskOwner) adds, changes or removes shares (MBX_SetTaskShare), picking from
	  MBX_TaskShareCandidates: users whose own account is in the assigner's company and who
	  hold the task's permission (the form's grant, Dynamic Reports, or Exams; Global Admin
	  counts for all three), not the assigner or assignee.
	- MBX_IsTaskAssigner now means "the assigner, or a colleague with 'manage' access", so
	  Mark as Completed, Remind, Cancel and the exam's management view (with its writes)
	  follow it everywhere. The old meaning is MBX_IsTaskOwner.
	- MBX_CanViewTask: the assigner or anyone the task is shared with ('manage' or 'read').
	  Read-only colleagues see the message and its task status, a completed Dynamic Report
	  (without editing rows), and the exam's management view as role 'Viewer' with no writes.
	- MBX_GetMessage, MBX_GetExamAccess, MBX_GetDRItemReport, MBX_GetDRRowAccess and
	  MBX_CreateHandoffCode accept those colleagues on a message that carries the shared task.
	  MBX_GetMessage reports SharedAccess so the page can say how it was shared. They see it
	  the way its sender does in Sent (no reply, no archive). Replies aren't shared.
	- MBX_GetAssignedTasks: scopes 'mine' (I assigned), 'shared' (shared with me) and
	  'company'; adds MyAccess, IsOwner and ShareCount.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.MBX_TaskShare', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_TaskShare](
		[ShareID] [int] IDENTITY(1,1) NOT NULL,
		[TaskID] [int] NOT NULL,
		[UID] [int] NOT NULL,
		[Access] [varchar](10) NOT NULL,
		[GrantedByUID] [int] NOT NULL,
		[DTGranted] [datetime] NOT NULL CONSTRAINT [DF_MBX_TaskShare_DTGranted] DEFAULT (getdate()),
		[Active] [bit] NOT NULL CONSTRAINT [DF_MBX_TaskShare_Active] DEFAULT (1),
		[DTRevoked] [datetime] NULL,
	 CONSTRAINT [PK_MBX_TaskShare] PRIMARY KEY CLUSTERED ([ShareID] ASC),
	 CONSTRAINT [FK_MBX_TaskShare_MBX_Task] FOREIGN KEY([TaskID]) REFERENCES [dbo].[MBX_Task] ([TaskID]),
	 CONSTRAINT [CK_MBX_TaskShare_Access] CHECK ([Access] IN ('manage', 'read'))
	) ON [PRIMARY]

	CREATE INDEX [IX_MBX_TaskShare_TaskID] ON [dbo].[MBX_TaskShare] ([TaskID], [Active])
	CREATE INDEX [IX_MBX_TaskShare_UID] ON [dbo].[MBX_TaskShare] ([UID], [Active])
END
GO

-- The task's real assigner (any of their accounts, by email): 014's MBX_IsTaskAssigner.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskOwner](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @r BIT = 0
	SELECT @r = 1
	FROM MBX_Task t
	JOIN Users a ON a.UID = t.AssignedByUID
	JOIN Users me ON me.UID = @UID
	WHERE t.TaskID = @TaskID
	AND (t.AssignedByUID = @UID OR (a.Email = me.Email AND me.Active = 1))
	RETURN @r
END
GO

-- The caller's shared access to a task ('manage' wins over 'read'), by account or email;
-- NULL if it isn't shared with them.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareAccess](@TaskID INT, @UID INT)
RETURNS VARCHAR(10)
AS
BEGIN
	DECLARE @a VARCHAR(10)
	SELECT TOP 1 @a = sh.Access
	FROM MBX_TaskShare sh
	JOIN Users su ON su.UID = sh.UID AND su.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE sh.TaskID = @TaskID AND sh.Active = 1
	AND (sh.UID = @UID OR su.Email = me.Email)
	ORDER BY CASE sh.Access WHEN 'manage' THEN 0 ELSE 1 END
	RETURN @a
END
GO

-- The assigner, or a colleague the task is shared with for 'manage'.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskAssigner](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 1 RETURN 1
	IF dbo.MBX_TaskShareAccess(@TaskID, @UID) = 'manage' RETURN 1
	RETURN 0
END
GO

-- The assigner or anyone the task is shared with.
CREATE OR ALTER FUNCTION [dbo].[MBX_CanViewTask](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 1 RETURN 1
	IF dbo.MBX_TaskShareAccess(@TaskID, @UID) IS NOT NULL RETURN 1
	RETURN 0
END
GO

-- A task on this message is shared with the caller: their way into a message they neither
-- sent nor received.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsSharedOnMessage](@MessageID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (
		SELECT 1
		FROM MBX_MessageItem mi
		JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
		JOIN MBX_TaskShare sh ON sh.TaskID = t.TaskID AND sh.Active = 1
		WHERE mi.MessageID = @MessageID
		AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL
	) RETURN 1
	RETURN 0
END
GO

-- Colleagues the assigner may share a task with: own account in the assigner's company,
-- holding the task's permission (same rules as the assignee pickers: the form's grant
-- (team or 'Form Applications' group), 'Dynamic Reports', or 'Exams'; Global Admin for
-- all), not the assigner or assignee. Empty unless the caller is the task's real assigner.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareCandidates](@UID INT, @TaskID INT)
RETURNS @r TABLE (UID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
AS
BEGIN
	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0 RETURN

	DECLARE @TaskType VARCHAR(20), @FormID VARCHAR(100), @ByUID INT, @ToUID INT
	SELECT @TaskType = TaskType, @FormID = FormID, @ByUID = AssignedByUID, @ToUID = AssignedToUID
	FROM MBX_Task WHERE TaskID = @TaskID

	DECLARE @MyCID INT = dbo.mycid(@UID)
	DECLARE @co TABLE (MgtUID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
	INSERT INTO @co
	SELECT DISTINCT u.MgtUID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	WHERE u.cid = @MyCID AND dbo.mycid(u.MgtUID) = @MyCID

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

	INSERT INTO @r
	SELECT DISTINCT c.MgtUID, c.Name, c.Email, c.Company
	FROM @co c
	WHERE c.MgtUID IN (SELECT MgtUID FROM @ok)
	AND c.MgtUID NOT IN (@UID, @ByUID, @ToUID)

	RETURN
END
GO

-- The task's current shares (the assigner only).
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskShares]
	@UID INT,
	@TaskID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	SELECT sh.UID, u.Fname + ' ' + u.Lname AS Name, u.Email, c.Company, sh.Access, sh.DTGranted
	FROM MBX_TaskShare sh
	JOIN Users u ON u.UID = sh.UID
	LEFT JOIN Companies c ON c.CID = dbo.mycid(sh.UID)
	WHERE sh.TaskID = @TaskID AND sh.Active = 1
	ORDER BY u.Lname, u.Fname
END
GO

-- Colleagues the task isn't shared with yet who could be (the assigner only).
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskShareCandidates]
	@UID INT,
	@TaskID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	SELECT c.UID, c.Name, c.Email, c.Company
	FROM dbo.MBX_TaskShareCandidates(@UID, @TaskID) c
	WHERE NOT EXISTS (SELECT 1 FROM MBX_TaskShare sh WHERE sh.TaskID = @TaskID AND sh.UID = c.UID AND sh.Active = 1)
	ORDER BY c.Name
END
GO

-- Adds or changes a share (@Access 'manage' or 'read'), or removes it (@Access 'none').
-- The assigner only, and only to a current candidate.
CREATE OR ALTER PROCEDURE [dbo].[MBX_SetTaskShare]
	@UID INT,
	@TaskID INT,
	@ShareUID INT,
	@Access VARCHAR(10)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	IF @Access = 'none'
	BEGIN
		UPDATE MBX_TaskShare SET Active = 0, DTRevoked = getdate()
		WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1
		SELECT @TaskID AS TaskID
		RETURN
	END

	IF @Access NOT IN ('manage', 'read')
	BEGIN
		SELECT 'bad_access' AS err
		RETURN
	END

	IF NOT EXISTS (SELECT 1 FROM dbo.MBX_TaskShareCandidates(@UID, @TaskID) WHERE UID = @ShareUID)
	BEGIN
		SELECT 'not_allowed' AS err
		RETURN
	END

	IF EXISTS (SELECT 1 FROM MBX_TaskShare WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1)
		UPDATE MBX_TaskShare SET Access = @Access, GrantedByUID = @UID, DTGranted = getdate()
		WHERE TaskID = @TaskID AND UID = @ShareUID AND Active = 1
	ELSE
		INSERT INTO MBX_TaskShare (TaskID, UID, Access, GrantedByUID)
		VALUES (@TaskID, @ShareUID, @Access, @UID)

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
			(SELECT COUNT(*) FROM MBX_TaskShare sh WHERE sh.TaskID = t.TaskID AND sh.Active = 1) AS ShareCount
		FROM MBX_Task t
		JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
		JOIN MBX_Message m ON m.MessageID = mi.MessageID AND m.IsDeleted = 0
		JOIN Users ab ON ab.UID = t.AssignedByUID
		JOIN Users at ON at.UID = t.AssignedToUID
		LEFT JOIN Companies atc ON atc.CID = dbo.mycid(t.AssignedToUID)
		WHERE (
			(@Scope = 'company' AND dbo.mycid(t.AssignedByUID) = @MyCID)
			OR (@Scope = 'shared' AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 0 AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL)
			OR (@Scope <> 'shared' AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 1)
		)
	) x
	ORDER BY x.DTCreated DESC, x.TaskID
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
	-- doesn't exist" for anyone else — never confirm existence of a message the
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

	IF @IsRecipient = 0 AND @IsAuthor = 0 AND @SharedAccess IS NULL
	BEGIN
		RETURN
	END

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames,
		@SharedAccess AS SharedAccess
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
		CASE WHEN t.AssignedToUID = @UID THEN 1 ELSE 0 END AS IsMyTask,
		CASE WHEN t.TaskID IS NOT NULL THEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) ELSE 0 END AS IsAssigner,
		ot.OriginTaskType,
		ot.OriginTaskStatus,
		ot.OriginDueDate,
		CASE WHEN ot.OriginTaskStatus = 'Pending Review' AND ot.CallerIsAssigner = 1 THEN ot.OriginTaskItemID END AS ReviewTaskItemID
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
	WHERE mi.MessageID = @MessageID
	ORDER BY mi.MessageItemID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetExamAccess]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @OriginItemID INT, @MessageID INT

	SELECT @MessageID = mi.MessageID,
		@OriginItemID = CASE mi.ItemType
			WHEN 'ExamTask' THEN mi.MessageItemID
			WHEN 'ExamRef' THEN TRY_CAST(mi.ItemID AS INT)
		END
	FROM MBX_MessageItem mi
	WHERE mi.MessageItemID = @MessageItemID AND mi.ItemType IN ('ExamTask', 'ExamRef')

	IF @OriginItemID IS NULL RETURN

	-- Recipient or author of the message this item (original or copy) is on.
	-- or (sql/026) a colleague this exam task is shared with
	IF NOT EXISTS (
		SELECT 1 FROM MBX_Message m
		WHERE m.MessageID = @MessageID
		AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = m.MessageID AND r.ToUID = @UID))
	) AND NOT EXISTS (
		SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = @OriginItemID AND t.TaskType = 'Exam' AND dbo.MBX_CanViewTask(t.TaskID, @UID) = 1
	)
		RETURN

	SELECT x.*,
		CAST(CASE
			WHEN x.TaskStatus = 'Cancelled' THEN 0
			WHEN x.Role = 'Assignee' AND x.TaskStatus = 'Completed' THEN 0
			WHEN x.Role = 'Viewer' THEN 0
			ELSE 1 END AS BIT) AS CanWrite
	FROM (
		SELECT t.TaskID, t.MessageItemID AS OriginItemID, t.ExamID, t.ExamCID,
			n.Name AS ExamName, c.Company AS ExamCompany,
			dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
			CASE
				WHEN dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1 THEN 'Assignee'
				WHEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 1 THEN 'Assigner'
				WHEN dbo.MBX_CanViewTask(t.TaskID, @UID) = 1 THEN 'Viewer'   -- shared read-only (sql/026)
			END AS Role
		FROM MBX_Task t
		JOIN MBX_MessageItem omi ON omi.MessageItemID = t.MessageItemID AND omi.ItemType = 'ExamTask'
		JOIN a_aMgtExamNames n ON n.ExamID = t.ExamID AND n.Active = 1
		JOIN a_aMgtExamShare s ON s.ExamID = t.ExamID AND s.xCID = t.ExamCID AND s.Active = 1 AND s.Shared = 1
		JOIN AccessTreeDown(@UID) atd ON atd.CID = t.ExamCID AND atd.Down = 1
		JOIN Companies c ON c.CID = t.ExamCID
		WHERE t.MessageItemID = @OriginItemID AND t.TaskType = 'Exam'
	) x
	WHERE x.Role IS NOT NULL
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRItemReport]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT mi.ItemID AS ReportID
	FROM MBX_MessageItem mi
	JOIN MBX_Message m ON m.MessageID = mi.MessageID
	WHERE mi.MessageItemID = @MessageItemID
	AND mi.ItemType IN ('DRTask', 'DynamicReport')
	AND mi.ItemID <> '0'
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID)
		-- sql/026: or a colleague the item's task is shared with
		OR EXISTS (SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = mi.MessageItemID AND dbo.MBX_CanViewTask(t.TaskID, @UID) = 1))
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

	SELECT @ReportID = mi.ItemID
	FROM MBX_MessageItem mi
	JOIN MBX_Message m ON m.MessageID = mi.MessageID
	WHERE mi.MessageItemID = @MessageItemID
	AND mi.ItemType IN ('DRTask', 'DynamicReport')
	AND mi.ItemID <> '0'
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID)
		-- sql/026: or a colleague the item's task is shared with
		OR EXISTS (SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = mi.MessageItemID AND dbo.MBX_CanViewTask(t.TaskID, @UID) = 1))

	IF @ReportID IS NULL RETURN

	SELECT dr.id AS DRID, dr.ReportID,
		-- A read-only share never edits rows (sql/026).
		CAST(CASE WHEN dbo.mycid(dr.CreatedBy) = dbo.mycid(@UID)
			AND NOT EXISTS (
				SELECT 1 FROM MBX_Task t
				WHERE t.MessageItemID = @MessageItemID
				AND dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 0 AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 0
				AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) = 'read')
			THEN 1 ELSE 0 END AS BIT) AS IsMine
	FROM NEO_DynamicReports dr
	JOIN AccessTreeDown(@UID) atd ON atd.CID = dbo.mycid(dr.CreatedBy) AND atd.Down = 1
	WHERE dr.id = @DRID
	AND dr.ReportID = @ReportID
	AND dr.active = 1
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_CreateHandoffCode]
	@UID INT,
	@MessageID INT = NULL,
	@Code VARCHAR(64)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MailboxUID INT

	IF ISNULL(@MessageID, 0) = 0
	BEGIN
		SELECT @MailboxUID = UID FROM Users WHERE UID = @UID AND Active = 1
		IF @MailboxUID IS NULL RETURN

		DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

		INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
		SELECT @Code, @MailboxUID, NULL, @UID, DATEADD(SECOND, 60, getdate())

		SELECT @Code AS Code, CAST(NULL AS INT) AS MessageID
		RETURN
	END

	SELECT TOP 1 @MailboxUID = r.ToUID
	FROM MBX_Recipient r
	JOIN Users ru ON ru.UID = r.ToUID AND ru.Active = 1
	JOIN Users me ON me.UID = @UID AND me.Active = 1
	WHERE r.MessageID = @MessageID
	AND ru.Email = me.Email
	ORDER BY CASE WHEN r.ToUID = @UID THEN 0 ELSE 1 END

	IF @MailboxUID IS NULL
		SELECT @MailboxUID = m.FromUID
		FROM MBX_Message m
		JOIN Users au ON au.UID = m.FromUID AND au.Active = 1
		JOIN Users me ON me.UID = @UID AND me.Active = 1
		WHERE m.MessageID = @MessageID
		AND m.IsDeleted = 0
		AND au.Email = me.Email

	-- sql/026: or a colleague a task on this message is shared with (their own account)
	IF @MailboxUID IS NULL AND dbo.MBX_IsSharedOnMessage(@MessageID, @UID) = 1
		SELECT @MailboxUID = UID FROM Users WHERE UID = @UID AND Active = 1

	IF @MailboxUID IS NULL RETURN

	-- Housekeeping: codes are worthless after a minute.
	DELETE FROM MBX_HandoffCode WHERE DTExpires < DATEADD(DAY, -1, getdate())

	INSERT INTO MBX_HandoffCode (Code, UID, MessageID, CreatedByUID, DTExpires)
	SELECT @Code, @MailboxUID, @MessageID, @UID, DATEADD(SECOND, 60, getdate())

	SELECT @Code AS Code, @MessageID AS MessageID
END
GO
