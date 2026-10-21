/*
	Dynamic Report viewer in CMSMailbox. Requires 006-009.

	A completed Dynamic Report task's item (ItemType 'DRTask', ItemID = the ReportID)
	now opens the report itself. Each row's values can be edited (by the row's own
	company), and notes and attachments can be added. Replies carry the completed
	report as a view-only 'DynamicReport' item, so the assigner can open it from the
	reply as well as from Sent.

	CMSNEO's own record procs (NEO_DynamicReports_GetDocs, NEO_DynamicReport_AttachDoc
	/ _DeleteDoc, NEO_GetFileNotes, NEO_InsUpdDelFileNotes) don't check access, so
	CMSMailbox's DRViewController checks every request itself first, using the procs
	below:
	  - MBX_GetDRItemReport: the item is a report this caller may open from this
	    message (recipient OR author of the message; task completed).
	  - MBX_GetDRRowAccess: additionally, the row belongs to that report and passes
	    CMSNEO's own report-visibility rule (NEO_GetDynamicReportsALL2: the row's
	    company is in AccessTreeDown(caller) with Down = 1). Returns IsMine (row's
	    company = caller's company; CMSNEO only lets that company edit values, and
	    NEO_DynamicRecordUpdate re-checks it).
	  - MBX_GetDRShareCompanies: companies a note on the row can be shared with: the
	    other participants of this message whose users can themselves see the row.

	- MBX_MessageItem.ItemType: allows 'DynamicReport'.
	- MBX_SendReply: also carries completed Dynamic Report task items, as 'DynamicReport'.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER TABLE [dbo].[MBX_MessageItem] DROP CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO
ALTER TABLE [dbo].[MBX_MessageItem] WITH CHECK ADD CONSTRAINT [CK_MBX_MessageItem_ItemType]
CHECK ([ItemType] IN ('File','FollowupAttachment','IAField','DRField','ExamFile','IAFormRecord','DRTask','DynamicReport'))
GO
ALTER TABLE [dbo].[MBX_MessageItem] CHECK CONSTRAINT [CK_MBX_MessageItem_ItemType]
GO

-- The ReportID behind a report item, if the caller may open it from this message.
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
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID))
END
GO

-- One row of that report, if the caller may see it (see the header). @DRID is the
-- row's NEO_DynamicReports.id (positive).
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
	AND (m.FromUID = @UID OR EXISTS (SELECT 1 FROM MBX_Recipient r WHERE r.MessageID = mi.MessageID AND r.ToUID = @UID))

	IF @ReportID IS NULL RETURN

	SELECT dr.id AS DRID, dr.ReportID,
		CAST(CASE WHEN dbo.mycid(dr.CreatedBy) = dbo.mycid(@UID) THEN 1 ELSE 0 END AS BIT) AS IsMine
	FROM NEO_DynamicReports dr
	JOIN AccessTreeDown(@UID) atd ON atd.CID = dbo.mycid(dr.CreatedBy) AND atd.Down = 1
	WHERE dr.id = @DRID
	AND dr.ReportID = @ReportID
	AND dr.active = 1
END
GO

-- Companies a note on this row can be shared with: the companies of the message's
-- other participants (sender + recipients), each only if that participant can see
-- the row themselves. Assumes MBX_GetDRRowAccess already passed for the caller.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetDRShareCompanies]
	@UID INT,
	@MessageItemID INT,
	@DRID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DECLARE @RowCID INT = (SELECT dbo.mycid(CreatedBy) FROM NEO_DynamicReports WHERE id = @DRID)
	DECLARE @MyCID INT = dbo.mycid(@UID)

	;WITH participants AS (
		SELECT m.FromUID AS UID
		FROM MBX_MessageItem mi JOIN MBX_Message m ON m.MessageID = mi.MessageID
		WHERE mi.MessageItemID = @MessageItemID
		UNION
		SELECT r.ToUID
		FROM MBX_MessageItem mi JOIN MBX_Recipient r ON r.MessageID = mi.MessageID
		WHERE mi.MessageItemID = @MessageItemID
	)
	SELECT DISTINCT c.CID, c.Company
	FROM participants p
	CROSS APPLY (SELECT dbo.mycid(p.UID) AS CID) pc
	JOIN Companies c ON c.CID = pc.CID
	WHERE p.UID <> @UID
	AND pc.CID <> @MyCID
	AND EXISTS (SELECT 1 FROM AccessTreeDown(p.UID) atd WHERE atd.CID = @RowCID AND atd.Down = 1)
	ORDER BY c.Company
END
GO

-- Same as 006's version, plus: a completed Dynamic Report task item is carried onto
-- the reply as a view-only 'DynamicReport' item (no task attached to it).
CREATE OR ALTER PROCEDURE [dbo].[MBX_SendReply]
	@UID INT,
	@ReplyToMessageID INT,
	@Subject NVARCHAR(255),
	@Body NVARCHAR(MAX) = NULL
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (
		SELECT 1 FROM MBX_Message WHERE MessageID = @ReplyToMessageID AND (FromUID = @UID OR EXISTS (
			SELECT 1 FROM MBX_Recipient WHERE MessageID = @ReplyToMessageID AND ToUID = @UID
		))
	)
	BEGIN
		RETURN
	END

	DECLARE @FromCID INT = dbo.mycid(@UID)
	DECLARE @NewMessageID INT

	INSERT INTO MBX_Message (FromUID, FromCID, Subject, Body, ReplyToMessageID)
	SELECT @UID, @FromCID, @Subject, @Body, @ReplyToMessageID

	SELECT @NewMessageID = SCOPE_IDENTITY()

	;WITH participants AS (
		SELECT FromUID AS UID FROM MBX_Message WHERE MessageID = @ReplyToMessageID
		UNION
		SELECT ToUID FROM MBX_Recipient WHERE MessageID = @ReplyToMessageID
	)
	INSERT INTO MBX_Recipient (MessageID, ToUID, ToCID)
	SELECT @NewMessageID, u.UID, u.CID
	FROM participants p
	JOIN Users u ON u.UID = p.UID AND u.Active = 1
	WHERE p.UID <> @UID

	-- Carry forward the Form Application record(s) and completed Dynamic Reports, if
	-- any, from the message being replied to. These are NEW MBX_MessageItem rows on
	-- the reply (not shared references to the old ones) — access is still
	-- independently re-verified at open time regardless, same as any other item.
	INSERT INTO MBX_MessageItem (MessageID, ItemType, ItemID, ItemLabel, OwnerCID, FormID)
	SELECT @NewMessageID,
		CASE WHEN mi.ItemType = 'DRTask' THEN 'DynamicReport' ELSE mi.ItemType END,
		mi.ItemID, mi.ItemLabel, mi.OwnerCID, mi.FormID
	FROM MBX_MessageItem mi
	WHERE mi.MessageID = @ReplyToMessageID
	AND mi.ItemType IN ('IAFormRecord', 'DRTask', 'DynamicReport')
	AND mi.ItemID <> '0'

	SELECT @NewMessageID AS MessageID
END
GO
