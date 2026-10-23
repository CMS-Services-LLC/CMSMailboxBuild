/*
	Phase 7, assignee side: whoever was assigned a task can share it with colleagues in their
	own company who hold the task's permission. Manage = work on the task as the assignee
	would (fill in and Save for Use the form, upload the Dynamic Report, answer the exam);
	Read only = open it and follow its status. Requires 026.

	- MBX_TaskShare.Side: 'assigner' (026's shares) or 'assignee'. 026's MBX_TaskShareAccess
	  now counts assigner-side shares only; MBX_AssigneeShareAccess is the assignee side.
	- MBX_IsTaskAssignee now means "the assignee, or a colleague they shared it with for
	  'manage'", so every assignee check follows it. The original meaning is
	  MBX_IsTaskAssigneeOwner. The checks that compared AssignedToUID directly
	  (MBX_GetOpenFormTask, MBX_LinkFormTask, MBX_GetDRTask, MBX_CompleteDRTask) use it now.
	- MBX_CanOpenItem: a recipient of the item's message, or a colleague the item's task is
	  shared with by its assignee. CMSMailbox's form viewer and item download use it in place
	  of "is a recipient".
	- MBX_GetMessage: those colleagues see the message as its recipient does, but only the
	  shared task's item, without reply or archive (AssigneeSharedAccess). Read-only ones get
	  a read-only exam (role 'AssigneeViewer') and no form/report work.
	- MBX_GetFolder: shared tasks also appear in the colleague's Inbox (IsShared = 1).
	- Share procs take @Side ('assigner' default, or 'assignee'); MBX_TaskShareCandidates
	  takes it too. MBX_GetAssignedTasks adds scopes 'received' (assigned to me) and
	  'receivedshared' (shared with me by an assignee) for CMS's My Tasks.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Two batches: SQL Server compiles a whole batch first, so a constraint can't name a column
-- added earlier in the same batch.
IF COL_LENGTH('dbo.MBX_TaskShare', 'Side') IS NULL
	ALTER TABLE [dbo].[MBX_TaskShare] ADD [Side] [varchar](10) NOT NULL CONSTRAINT [DF_MBX_TaskShare_Side] DEFAULT ('assigner')
GO
IF OBJECT_ID('dbo.CK_MBX_TaskShare_Side', 'C') IS NULL
	EXEC('ALTER TABLE [dbo].[MBX_TaskShare] WITH CHECK ADD CONSTRAINT [CK_MBX_TaskShare_Side] CHECK ([Side] IN (''assigner'', ''assignee''))')
GO

-- 026's share access, assigner side only.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareAccess](@TaskID INT, @UID INT)
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

-- The caller's access to a task shared by its assignee ('manage' wins), or NULL.
CREATE OR ALTER FUNCTION [dbo].[MBX_AssigneeShareAccess](@TaskID INT, @UID INT)
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

-- The task's real assignee (any of their accounts, by email): 015's MBX_IsTaskAssignee.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskAssigneeOwner](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	DECLARE @r BIT = 0
	SELECT @r = 1
	FROM MBX_Task t
	JOIN Users a ON a.UID = t.AssignedToUID
	JOIN Users me ON me.UID = @UID
	WHERE t.TaskID = @TaskID
	AND (t.AssignedToUID = @UID OR (a.Email = me.Email AND me.Active = 1))
	RETURN @r
END
GO

-- The assignee, or a colleague they shared the task with for 'manage'.
CREATE OR ALTER FUNCTION [dbo].[MBX_IsTaskAssignee](@TaskID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) = 1 RETURN 1
	IF dbo.MBX_AssigneeShareAccess(@TaskID, @UID) = 'manage' RETURN 1
	RETURN 0
END
GO

-- A recipient of the item's message, or a colleague the item's task was shared with by its
-- assignee: who may open the item (form record, download) in the mailbox.
CREATE OR ALTER FUNCTION [dbo].[MBX_CanOpenItem](@MessageItemID INT, @UID INT)
RETURNS BIT
AS
BEGIN
	IF EXISTS (
		SELECT 1 FROM MBX_MessageItem mi
		JOIN MBX_Recipient r ON r.MessageID = mi.MessageID AND r.ToUID = @UID
		WHERE mi.MessageItemID = @MessageItemID
	) RETURN 1
	IF EXISTS (
		SELECT 1 FROM MBX_Task t
		WHERE t.MessageItemID = @MessageItemID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL
	) RETURN 1
	RETURN 0
END
GO

-- A task on this message is shared with the caller, by either side (handoff).
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
		AND (dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	) RETURN 1
	RETURN 0
END
GO

-- sql/028: @Side 'assigner' (the assigner's colleagues) or 'assignee' (the assignee's,
-- in the assignee's company). The caller must be that side's own person.
CREATE OR ALTER FUNCTION [dbo].[MBX_TaskShareCandidates](@UID INT, @TaskID INT, @Side VARCHAR(10))
RETURNS @r TABLE (UID INT, Name VARCHAR(200), Email VARCHAR(300), Company VARCHAR(300))
AS
BEGIN
	IF @Side = 'assignee' AND dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) = 0 RETURN
	IF @Side <> 'assignee' AND dbo.MBX_IsTaskOwner(@TaskID, @UID) = 0 RETURN

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

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskShares]
	@UID INT,
	@TaskID INT,
	@Side VARCHAR(10) = 'assigner'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF (CASE WHEN @Side = 'assignee' THEN dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) ELSE dbo.MBX_IsTaskOwner(@TaskID, @UID) END) = 0
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

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskShareCandidates]
	@UID INT,
	@TaskID INT,
	@Side VARCHAR(10) = 'assigner'
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF (CASE WHEN @Side = 'assignee' THEN dbo.MBX_IsTaskAssigneeOwner(@TaskID, @UID) ELSE dbo.MBX_IsTaskOwner(@TaskID, @UID) END) = 0
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	SELECT c.UID, c.Name, c.Email, c.Company
	FROM dbo.MBX_TaskShareCandidates(@UID, @TaskID, ISNULL(NULLIF(@Side, ''), 'assigner')) c
	WHERE NOT EXISTS (SELECT 1 FROM MBX_TaskShare sh WHERE sh.TaskID = @TaskID AND sh.UID = c.UID AND sh.Active = 1 AND sh.Side = ISNULL(NULLIF(@Side, ''), 'assigner'))
	ORDER BY c.Name
END
GO

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
			(@Scope = 'company' AND dbo.mycid(t.AssignedByUID) = @MyCID)
			OR (@Scope = 'shared' AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 0 AND dbo.MBX_TaskShareAccess(t.TaskID, @UID) IS NOT NULL)
			OR (@Scope IN ('mine', 'company') AND dbo.MBX_IsTaskOwner(t.TaskID, @UID) = 1)
			-- sql/028, CMS's My Tasks
			OR (@Scope = 'received' AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 1)
			OR (@Scope = 'receivedshared' AND dbo.MBX_IsTaskAssigneeOwner(t.TaskID, @UID) = 0 AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
		)
	) x
	ORDER BY x.DTCreated DESC, x.TaskID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetOpenFormTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT t.TaskID, t.FormID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'FormApplication'
	AND t.Status = 'Open'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1   -- sql/028: or a 'manage' colleague
	AND dbo.MBX_CanOpenItem(mi.MessageItemID, @UID) = 1
	AND mi.ItemType = 'IAFormRecord'
	AND mi.ItemID = '0'
	AND t.FormID IS NOT NULL
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_LinkFormTask]
	@UID INT,
	@MessageItemID INT,
	@MainID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT, @FormID VARCHAR(100)

	SELECT @TaskID = t.TaskID, @FormID = t.FormID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'FormApplication'
	AND t.Status = 'Open'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1   -- sql/028: or a 'manage' colleague
	AND mi.ItemID = '0'

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no unstarted form task for this item and user' AS err
		RETURN
	END

	IF NOT EXISTS (
		SELECT 1 FROM NEO_IAFormRecords
		WHERE ID = @MainID AND FormID = @FormID AND UID = @UID AND active = 1
	)
	BEGIN
		SELECT 'record is not a new record of this form created by this user' AS err
		RETURN
	END

	UPDATE MBX_MessageItem SET ItemID = CAST(@MainID AS NVARCHAR(50))
	WHERE MessageItemID = @MessageItemID

	UPDATE MBX_Task SET ResultID = CAST(@MainID AS NVARCHAR(100))
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID, @MainID AS MainID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRTask]
	@UID INT,
	@MessageItemID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT t.TaskID, t.Status, t.ReportName, t.ReportType, t.TemplateFileName, t.TemplateHeaders, t.TemplateBytes, t.ResultID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'DynamicReport'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1   -- sql/028: or a 'manage' colleague
	AND dbo.MBX_CanOpenItem(mi.MessageItemID, @UID) = 1
	AND mi.ItemType = 'DRTask'
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_CompleteDRTask]
	@UID INT,
	@MessageItemID INT,
	@ReportID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @TaskID INT

	SELECT @TaskID = t.TaskID
	FROM MBX_Task t
	JOIN MBX_MessageItem mi ON mi.MessageItemID = t.MessageItemID
	WHERE t.MessageItemID = @MessageItemID
	AND t.TaskType = 'DynamicReport'
	AND t.Status = 'Open'
	AND dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1   -- sql/028: or a 'manage' colleague
	AND mi.ItemID = '0'

	IF @TaskID IS NULL
	BEGIN
		SELECT 'no open dynamic report task for this item and user' AS err
		RETURN
	END

	IF NOT EXISTS (SELECT 1 FROM NEO_DynamicReports WHERE ReportID = @ReportID AND CreatedBy = @UID)
	BEGIN
		SELECT 'report not found for this user' AS err
		RETURN
	END

	UPDATE MBX_MessageItem SET ItemID = CAST(@ReportID AS NVARCHAR(50))
	WHERE MessageItemID = @MessageItemID

	UPDATE MBX_Task SET Status = 'Completed', ResultID = @ReportID, DTCompleted = getdate()
	WHERE TaskID = @TaskID

	SELECT @TaskID AS TaskID, @ReportID AS ReportID
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
		SELECT 1 FROM MBX_Task t WHERE t.MessageItemID = @OriginItemID AND t.TaskType = 'Exam'
		AND (dbo.MBX_CanViewTask(t.TaskID, @UID) = 1 OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	)
		RETURN

	SELECT x.*,
		CAST(CASE
			WHEN x.TaskStatus = 'Cancelled' THEN 0
			WHEN x.Role = 'Assignee' AND x.TaskStatus = 'Completed' THEN 0
			WHEN x.Role IN ('Viewer', 'AssigneeViewer') THEN 0
			ELSE 1 END AS BIT) AS CanWrite
	FROM (
		SELECT t.TaskID, t.MessageItemID AS OriginItemID, t.ExamID, t.ExamCID,
			n.Name AS ExamName, c.Company AS ExamCompany,
			dbo.MBX_TaskStatusText(t.TaskID) AS TaskStatus,
			CASE
				WHEN dbo.MBX_IsTaskAssignee(t.TaskID, @UID) = 1 THEN 'Assignee'
				WHEN dbo.MBX_IsTaskAssigner(t.TaskID, @UID) = 1 THEN 'Assigner'
				WHEN dbo.MBX_CanViewTask(t.TaskID, @UID) = 1 THEN 'Viewer'   -- shared read-only (sql/026)
				WHEN dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL THEN 'AssigneeViewer'   -- the assignee's read-only colleague (sql/028)
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

	SELECT @ReportID = mi.ItemID
	FROM MBX_MessageItem mi
	JOIN MBX_Message m ON m.MessageID = mi.MessageID
	WHERE mi.MessageItemID = @MessageItemID
	AND mi.ItemType IN ('DRTask', 'DynamicReport')
	AND mi.ItemID <> '0'
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

	SELECT
		m.MessageID, m.Subject, m.Body, m.DTCreated, m.ReplyToMessageID,
		u.Fname + ' ' + u.Lname AS FromName,
		c.Company AS FromCompany,
		@IsRecipient AS IsRecipient,
		@IsArchived AS IsArchived,
		dbo.MBX_ToNames(m.MessageID) AS ToNames,
		@SharedAccess AS SharedAccess,
		@AssigneeSharedAccess AS AssigneeSharedAccess
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
	AND (@AssigneeSharedAccess IS NULL OR dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)
	ORDER BY mi.MessageItemID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetFolder]
	@UID INT,
	@Folder VARCHAR(20)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF @Folder IN ('inbox', 'archived')
	BEGIN
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			r.DTViewed,
			r.IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(0 AS BIT) AS IsShared
		FROM MBX_Recipient r
		JOIN MBX_Message m ON m.MessageID = r.MessageID AND m.IsDeleted = 0
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE r.ToUID = @UID
		  AND r.IsArchived = CASE WHEN @Folder = 'archived' THEN 1 ELSE 0 END

		UNION ALL

		-- sql/028: messages with a task the assignee shared with the caller (Inbox only)
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			CAST(getdate() AS DATETIME) AS DTViewed,
			CAST(0 AS BIT) AS IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			CAST(NULL AS NVARCHAR(MAX)) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(1 AS BIT) AS IsShared
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE @Folder = 'inbox' AND m.IsDeleted = 0
		  AND NOT EXISTS (SELECT 1 FROM MBX_Recipient r2 WHERE r2.MessageID = m.MessageID AND r2.ToUID = @UID)
		  AND EXISTS (
			SELECT 1 FROM MBX_MessageItem mi
			JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
			JOIN MBX_TaskShare sh ON sh.TaskID = t.TaskID AND sh.Active = 1 AND sh.Side = 'assignee'
			WHERE mi.MessageID = m.MessageID AND dbo.MBX_AssigneeShareAccess(t.TaskID, @UID) IS NOT NULL)

		ORDER BY DTCreated DESC
	END
	ELSE IF @Folder = 'sent'
	BEGIN
		SELECT
			m.MessageID,
			m.Subject,
			LEFT(ISNULL(m.Body,''), 200) AS Preview,
			m.DTCreated,
			CAST(NULL AS DATETIME) AS DTViewed,
			CAST(0 AS BIT) AS IsArchived,
			u.Fname + ' ' + u.Lname AS FromName,
			c.Company AS FromCompany,
			(SELECT COUNT(*) FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemCount,
			dbo.MBX_ToNames(m.MessageID) AS ToNames,
			ts.TaskState,
			(SELECT STRING_AGG(CAST(mi.ItemLabel AS NVARCHAR(MAX)), ' | ') FROM MBX_MessageItem mi WHERE mi.MessageID = m.MessageID) AS ItemLabels,
			CAST(0 AS BIT) AS IsShared
		FROM MBX_Message m
		JOIN Users u ON u.UID = m.FromUID
		JOIN Companies c ON c.CID = m.FromCID
		OUTER APPLY dbo.MBX_MessageTaskState(m.MessageID) ts
		WHERE m.FromUID = @UID AND m.IsDeleted = 0
		ORDER BY m.DTCreated DESC
	END
END
GO
