/*
	Assign Tasks drafts: the assigner saves an unfinished Assign Tasks wizard and comes back
	to it later. Requires 006.

	- MBX_TaskDraft: one row per draft, owned by the UID that saved it. DraftJSON is the
	  wizard's own state (tasks, assignee, due date, review, subject, message, step); CMS
	  stores and returns it as-is and re-validates everything when the tasks are sent.
	- MBX_TaskDraftFile: the Dynamic Report templates attached to a draft, by FileKey.
	- Every proc takes @UID and only touches that user's own drafts. Sending the tasks
	  deletes the draft (MBX_DeleteTaskDraft).

	Not reachable from CMS's browser dispatcher (that only runs NEO* and a_Suite_* procs);
	CMS calls these from MailboxShareController with the caller's validated UID.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF OBJECT_ID('dbo.MBX_TaskDraft', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_TaskDraft](
		[DraftID] [int] IDENTITY(1,1) NOT NULL,
		[UID] [int] NOT NULL,
		[Title] [nvarchar](255) NOT NULL,
		[DraftJSON] [nvarchar](max) NOT NULL,
		[DTCreated] [datetime] NOT NULL CONSTRAINT [DF_MBX_TaskDraft_DTCreated] DEFAULT (getdate()),
		[DTUpdated] [datetime] NOT NULL CONSTRAINT [DF_MBX_TaskDraft_DTUpdated] DEFAULT (getdate()),
	 CONSTRAINT [PK_MBX_TaskDraft] PRIMARY KEY CLUSTERED ([DraftID] ASC)
	) ON [PRIMARY]

	CREATE INDEX [IX_MBX_TaskDraft_UID] ON [dbo].[MBX_TaskDraft] ([UID])
END
GO

IF OBJECT_ID('dbo.MBX_TaskDraftFile', 'U') IS NULL
BEGIN
	CREATE TABLE [dbo].[MBX_TaskDraftFile](
		[DraftID] [int] NOT NULL,
		[FileKey] [varchar](50) NOT NULL,
		[FileName] [nvarchar](255) NOT NULL,
		[Bytes] [varbinary](max) NOT NULL,
	 CONSTRAINT [PK_MBX_TaskDraftFile] PRIMARY KEY CLUSTERED ([DraftID] ASC, [FileKey] ASC),
	 CONSTRAINT [FK_MBX_TaskDraftFile_MBX_TaskDraft] FOREIGN KEY([DraftID]) REFERENCES [dbo].[MBX_TaskDraft] ([DraftID]) ON DELETE CASCADE
	) ON [PRIMARY]
END
GO

-- Creates a draft (@DraftID 0) or replaces one of the caller's own. A new save replaces the
-- draft's files too: CMS sends every template the draft still has.
CREATE OR ALTER PROCEDURE [dbo].[MBX_SaveTaskDraft]
	@UID INT,
	@DraftID INT,
	@Title NVARCHAR(255),
	@DraftJSON NVARCHAR(MAX)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF ISNULL(@DraftID, 0) = 0
	BEGIN
		INSERT INTO MBX_TaskDraft (UID, Title, DraftJSON) VALUES (@UID, @Title, @DraftJSON)
		SELECT CAST(SCOPE_IDENTITY() AS INT) AS DraftID
		RETURN
	END

	IF NOT EXISTS (SELECT 1 FROM MBX_TaskDraft WHERE DraftID = @DraftID AND UID = @UID)
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	UPDATE MBX_TaskDraft SET Title = @Title, DraftJSON = @DraftJSON, DTUpdated = getdate()
	WHERE DraftID = @DraftID AND UID = @UID
	DELETE FROM MBX_TaskDraftFile WHERE DraftID = @DraftID

	SELECT @DraftID AS DraftID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_SaveTaskDraftFile]
	@UID INT,
	@DraftID INT,
	@FileKey VARCHAR(50),
	@FileName NVARCHAR(255),
	@Bytes VARBINARY(MAX)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	IF NOT EXISTS (SELECT 1 FROM MBX_TaskDraft WHERE DraftID = @DraftID AND UID = @UID)
	BEGIN
		SELECT 'not_found' AS err
		RETURN
	END

	DELETE FROM MBX_TaskDraftFile WHERE DraftID = @DraftID AND FileKey = @FileKey
	INSERT INTO MBX_TaskDraftFile (DraftID, FileKey, FileName, Bytes) VALUES (@DraftID, @FileKey, @FileName, @Bytes)
	SELECT @DraftID AS DraftID
END
GO

-- The caller's drafts, newest first.
CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskDrafts]
	@UID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT DraftID, Title, DTCreated, DTUpdated
	FROM MBX_TaskDraft
	WHERE UID = @UID
	ORDER BY DTUpdated DESC
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskDraft]
	@UID INT,
	@DraftID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT d.DraftID, d.Title, d.DraftJSON,
		(SELECT STRING_AGG(CAST(f.FileKey AS NVARCHAR(MAX)), ',') FROM MBX_TaskDraftFile f WHERE f.DraftID = d.DraftID) AS FileKeys
	FROM MBX_TaskDraft d
	WHERE d.DraftID = @DraftID AND d.UID = @UID
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_GetTaskDraftFile]
	@UID INT,
	@DraftID INT,
	@FileKey VARCHAR(50)
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	SELECT f.FileName, f.Bytes
	FROM MBX_TaskDraftFile f
	JOIN MBX_TaskDraft d ON d.DraftID = f.DraftID AND d.UID = @UID
	WHERE f.DraftID = @DraftID AND f.FileKey = @FileKey
END
GO

CREATE OR ALTER PROCEDURE [dbo].[MBX_DeleteTaskDraft]
	@UID INT,
	@DraftID INT
AS
BEGIN
	SET ARITHABORT ON
	SET NOCOUNT ON

	DELETE FROM MBX_TaskDraft WHERE DraftID = @DraftID AND UID = @UID
	SELECT @DraftID AS DraftID
END
GO
