/*  049 - "Update an existing report" tasks: management users can be assigned  (2026-11-18, John)

    John: picked another company's report and Assign Task said no one has access, but management
    users do. MBX_GetDRUpdateTaskCandidates (sql/048) required dbo.mycid(MgtUID) = the report's
    company, and a management user's real (MGT) account belongs to the management company.

    Now also offered: management users who have an account AT the report's company (the account
    CMS's company toggle switches to; neousers u.UID with u.cid = that company), offered as THAT
    account (u.UID, not u.MgtUID) and labelled "(<management company> management)", exactly like
    sql/044 does for exams. Edits and new rows then belong to the report's company, the only one
    that can change its rows. The mailbox's report viewer acts as that account when the same
    person (same email, MBX_IsTaskAssigneeOwner) signs in with their management account
    (DRViewController ActAs); Mark as Done already accepts them (MBX_IsTaskAssignee).

    Base = sql/048's MBX_GetDRUpdateTaskCandidates, unchanged except the management rows.
    Safe to re-run. After running: refresh QA_/PROD_Stored_Procedures.sql (MBX_GetDRUpdateTaskCandidates).
*/
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRUpdateTaskCandidates]
	@UID INT,
	@ReportID VARCHAR(100)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @OwnerCID INT = (SELECT TOP 1 dbo.mycid(CreatedBy) FROM NEO_DynamicReports WHERE ReportID = @ReportID AND active = 1 ORDER BY id)
	IF @OwnerCID IS NULL RETURN

	-- the caller must be able to see the report (same rule as MBX_GetAssignableReports)
	IF NOT EXISTS (SELECT 1 FROM AccessTreeDown(@UID) atd WHERE atd.CID = @OwnerCID AND atd.Down = 1) RETURN

	DECLARE @c TABLE (UID INT, Name VARCHAR(300), Email VARCHAR(300), Company VARCHAR(300))

	-- people whose own account is at the report's company
	INSERT INTO @c
	SELECT DISTINCT u.MgtUID, u.Name, u.Email, u.Company
	FROM neousers(@UID) u
	WHERE u.MgtUID <> @UID
	AND dbo.mycid(u.MgtUID) = @OwnerCID

	-- sql/049: management users with an account at the report's company, offered as that account
	INSERT INTO @c
	SELECT DISTINCT u.UID, u.Name + ' (' + ISNULL(u.MgtCompany, 'management') + ' management)', u.Email, u.Company
	FROM neousers(@UID) u
	WHERE u.cid = @OwnerCID
	AND dbo.mycid(u.UID) = @OwnerCID
	AND dbo.mycid(u.MgtUID) <> @OwnerCID
	AND u.UID <> @UID AND u.MgtUID <> @UID
	AND NOT EXISTS (SELECT 1 FROM @c x WHERE x.UID = u.UID)

	SELECT UID, Name, Email, Company FROM @c ORDER BY Name
END
GO

-- Test (QA): the report John picked
-- exec MBX_GetDRUpdateTaskCandidates @UID = <your uid>, @ReportID = '<ReportID>'
