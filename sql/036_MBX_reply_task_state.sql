/*
	"Tasks pending" / "Tasks completed" / "Tasks cancelled" on replies too. Requires 022.

	- MBX_MessageTaskState(@MessageID): same states as 022's version, but counts the tasks
	  on the message itself AND on the messages it replies to (up the ReplyToMessageID
	  chain). A reply carries no MBX_Task of its own (MBX_SendReply only copies items), so
	  until now it had no TaskState: the list showed no tag on it and the Pending /
	  Completed filter left it out. Now a reply shows the state of the task(s) its
	  conversation is about. A message with no tasks anywhere above it still returns no
	  row (NULL), as before.
	- MBX_GetFolder (031) calls this function, so it picks this up without being changed.

	Idempotent; safe to run more than once.
*/

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER FUNCTION [dbo].[MBX_MessageTaskState](@MessageID INT)
RETURNS TABLE
AS
RETURN (
	WITH up AS (
		SELECT MessageID, ReplyToMessageID, 0 AS Depth FROM MBX_Message WHERE MessageID = @MessageID
		UNION ALL
		SELECT m.MessageID, m.ReplyToMessageID, up.Depth + 1
		FROM MBX_Message m JOIN up ON m.MessageID = up.ReplyToMessageID
		WHERE up.Depth < 90
	)
	SELECT CASE
			WHEN SUM(CASE WHEN st.s NOT IN ('Completed', 'Cancelled') THEN 1 ELSE 0 END) > 0 THEN 'Pending'
			WHEN SUM(CASE WHEN st.s = 'Completed' THEN 1 ELSE 0 END) > 0 THEN 'Completed'
			ELSE 'Cancelled'
		END AS TaskState
	FROM up
	JOIN MBX_MessageItem mi ON mi.MessageID = up.MessageID
	JOIN MBX_Task t ON t.MessageItemID = mi.MessageItemID
	CROSS APPLY (SELECT dbo.MBX_TaskStatusText(t.TaskID) AS s) st
	HAVING COUNT(*) > 0
)
GO
