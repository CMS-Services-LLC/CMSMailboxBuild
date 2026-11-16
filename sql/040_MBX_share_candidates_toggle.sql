/*
	040 (2026-11-11): Share list empty for toggle (multi-company) accounts.

	John, signed in as Allgate and toggled to ARC (that's his ARC account, UID 8427), saw nobody in
	the Share dialog although Jon, Irwin, Lindsey and Yvette all have ARC accounts. Toggling
	switches to a separate account per company, and NEOUsers groups those accounts under the
	person's management account (MgtUID, an Allgate account). MBX_TaskShareCandidates required
	dbo.mycid(MgtUID) = my company, which is never true for a toggle person, so all of them were
	dropped; it also returned the MgtUID rather than the account they'd use in this company.

	Now: a colleague qualifies by having an account (NEOUsers row) in my current company; the
	permission checks stay on their MgtUID (where NEOUsers and CMS read their groups and Teams),
	and the candidate returned is that company's account (UID). The assigner and assignee are
	left out by email, since a person can have several accounts.

	Share access already matches by email (MBX_TaskShareAccess, MBX_IsTaskOwner), so no other
	object changes. Replaces the function from 028; same signature. Idempotent.
	Rollback: re-run the MBX_TaskShareCandidates section of 028_MBX_assignee_sharing.sql.
*/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
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

-- Check (read-only): your UID and task; expect your ARC colleagues with the task's permission.
-- select * from dbo.MBX_TaskShareCandidates(8427, 31, 'assigner')
-- select object_id('dbo.MBX_TaskShareCandidates') as FnID
