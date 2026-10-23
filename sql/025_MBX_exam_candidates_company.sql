/*
	Exam assignees must belong to the examined company. Requires 019.

	- MBX_GetExamTaskCandidates: same as 019's version, plus the candidate's own (MGT)
	  account must be at @XCID. 019 found accounts at the examined company but then
	  returned each person's MGT account, so people from other companies who merely
	  had a login at the examined company (e.g. management staff) were listed, and
	  could be assigned. CMS uses this list both for the picker and to check the
	  assignee on send, so this one change covers both.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
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
		JOIN a_aMgtExamShare s ON s.ExamID = n.ExamID AND s.xCID = @XCID AND s.Active = 1 AND s.Shared = 1
		JOIN AccessTreeDown(@UID) atd ON atd.CID = @XCID AND atd.Down = 1
		WHERE n.ExamID = @ExamID AND n.Active = 1 AND n.OwnerCID = @MyCID AND @XCID <> @MyCID
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
