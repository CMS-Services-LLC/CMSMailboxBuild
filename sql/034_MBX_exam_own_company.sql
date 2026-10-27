/*
	Exam tasks can be assigned to someone at your own company. Requires 028.

	Until now an exam task's examined company had to be a downstream company the exam
	is shared with, and your own company was excluded outright (xCID <> @MyCID). CMSNEO's
	own rule (NEO_MgtGetExam, NEO_MgtCreateExamSnapshot) is that an exam is visible to a
	company that owns it OR that it is shared with; this uses the same rule.

	- MBX_GetAssignableExams: 019's version plus the caller's own company, for every
	  active exam it owns (shared with itself or not).
	- MBX_GetExamTaskCandidates: 025's version, accepting @XCID = the caller's company.
	  The caller is still never a candidate.
	- MBX_GetExamAccess: 028's version; the exam viewer's gate also passes when the
	  examined company owns the exam.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- Exams the caller's company owns, with each company that may be examined on it: the
-- owner itself, and each company it is shared with (Shared = 1, active). Either way the
-- caller must reach that company down the tree (AccessTreeDown, Down = 1; their own
-- company counts).
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetAssignableExams]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	SELECT DISTINCT x.XCID, c.Company, n.ExamID, n.Name AS ExamName
	FROM a_aMgtExamNames n
	CROSS APPLY (
		SELECT s.xCID FROM a_aMgtExamShare s WHERE s.ExamID = n.ExamID AND s.Active = 1 AND s.Shared = 1
		UNION SELECT n.OwnerCID   -- sql/034: the owner may examine itself
	) x (XCID)
	JOIN AccessTreeDown(@UID) atd ON atd.CID = x.XCID AND atd.Down = 1
	JOIN Companies c ON c.CID = x.XCID
	WHERE n.Active = 1
	AND n.OwnerCID = @MyCID
	ORDER BY c.Company, n.Name
END
GO

-- Users at the examined company (@XCID) who can work exams: the 'Exams' user-group
-- permission or Global Admin, whose own account is at @XCID. Empty unless @ExamID is
-- one MBX_GetAssignableExams would offer the caller for @XCID.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetExamTaskCandidates]
	@UID INT,
	@XCID INT,
	@ExamID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @MyCID INT = dbo.mycid(@UID)

	IF NOT EXISTS (
		SELECT 1
		FROM a_aMgtExamNames n
		JOIN AccessTreeDown(@UID) atd ON atd.CID = @XCID AND atd.Down = 1
		WHERE n.ExamID = @ExamID AND n.Active = 1 AND n.OwnerCID = @MyCID
		AND (@XCID = n.OwnerCID   -- sql/034: your own company
			OR EXISTS (SELECT 1 FROM a_aMgtExamShare s WHERE s.ExamID = n.ExamID AND s.xCID = @XCID AND s.Active = 1 AND s.Shared = 1))
	)
		RETURN

	SELECT DISTINCT u.MgtUID AS UID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action IN ('Exams', 'Global Administrator')
	WHERE u.cid = @XCID
	AND dbo.mycid(u.MgtUID) = @XCID   -- sql/025: the person's own account is at the examined company
	AND u.MgtUID <> @UID
	ORDER BY u.Name
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
		JOIN AccessTreeDown(@UID) atd ON atd.CID = t.ExamCID AND atd.Down = 1
		JOIN Companies c ON c.CID = t.ExamCID
		WHERE t.MessageItemID = @OriginItemID AND t.TaskType = 'Exam'
		AND (t.ExamCID = n.OwnerCID   -- sql/034: the owner examining itself
			OR EXISTS (SELECT 1 FROM a_aMgtExamShare s WHERE s.ExamID = t.ExamID AND s.xCID = t.ExamCID AND s.Active = 1 AND s.Shared = 1))
	) x
	WHERE x.Role IS NOT NULL
END
GO
