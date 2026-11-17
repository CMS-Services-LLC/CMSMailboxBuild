/*
	044_MBX_exam_candidates_management.sql  (2026-11-17, John)

	Assign Tasks > Exam: when the examined company has no users of its own who can work exams,
	offer management users instead, i.e. people whose main account is at a management company
	above it and who hold 'Exams' or 'Global Administrator' there, AND who have an account at
	the examined company (the account CMS's company toggle switches to). The candidate is offered
	as THAT examined-company account (u.UID, not u.MgtUID), so the task, the exam view and every
	answer/upload belong to the examined company exactly as they would for its own user.
	CMSMailbox's exam viewer acts as that account when the same person (same email) signs in to
	the mailbox with their management account (IaViewerController.Exam.cs, ActAsUID).

	Base = QA's current MBX_GetExamTaskCandidates (sql/034), unchanged except the fallback.
	Form Application and Dynamic Report candidates already include management users; no change.

	Safe to re-run.  After running: refresh QA_Stored_Procedures.sql (or PROD_...).
*/

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

	DECLARE @c TABLE (UID INT, Name VARCHAR(300), Email VARCHAR(300), Company VARCHAR(300))

	INSERT INTO @c
	SELECT DISTINCT u.MgtUID AS UID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
	JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action IN ('Exams', 'Global Administrator')
	WHERE u.cid = @XCID
	AND dbo.mycid(u.MgtUID) = @XCID   -- sql/025: the person's own account is at the examined company
	AND u.MgtUID <> @UID

	-- sql/044: no one of its own, so management users with an account at the examined company,
	-- offered as that account.
	IF NOT EXISTS (SELECT 1 FROM @c)
		INSERT INTO @c
		SELECT DISTINCT u.UID, u.Name + ' (' + isnull(u.MgtCompany, 'management') + ' management)', u.Email, u.Company
		FROM neousers(@UID) u
		JOIN NEO_SecurityGroupAssignments sga ON sga.uid = u.MgtUID AND sga.active = 1
		JOIN vwSecurityGroups sg ON sg.GroupID = sga.groupid AND sg.action IN ('Exams', 'Global Administrator')
		WHERE u.cid = @XCID
		AND dbo.mycid(u.UID) = @XCID
		AND dbo.mycid(u.MgtUID) <> @XCID
		AND u.UID <> @UID AND u.MgtUID <> @UID

	SELECT UID, Name, Email, Company FROM @c ORDER BY Name
END
GO
