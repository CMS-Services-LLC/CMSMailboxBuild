# Wizard Assignments — "What would you like to do" → assign tasks via secure email

Branch: `wizard_assignments_20261021` in both **CMS** and **CMSMailbox**. Drafted 2026-10-21.

## Goal

From the CMSNEO dashboard, a management-company user opens a window from "What would you like to do?" and assigns one of three tasks to a user. The task arrives as a CMSMailbox message, and the assignee completes it there:

| Task | MGT user picks | Assignee does it in CMSMailbox |
|---|---|---|
| Dynamic Report | Uploads an Excel **template** and sets the report name/type | Downloads the template, fills it in Excel, and uploads it back. The headers must match the template. The upload becomes a normal Dynamic Report. |
| Exam | An exam from the company's available exams (`_MGTGetExams`) | **Works** the exam: answers questions and adds attachments (full exam viewer) |
| Form Application | A form (FormID) | Fills out a **new** record and saves it |

**Decisions made (2026-10-21):**
- A task only goes to users who **already have access** to the exam or form. This is the same rule as Share to Mailbox: assigning a task never grants access. The recipient picker is filtered to match.
- Dynamic Report = download, fill in, re-upload.
- Exam = full working viewer, not read-only.
- Tracking: no preference was given. Default: optional due date, plus Open/Completed status that is set automatically when the work is saved. An MGT-side task list comes in a later phase.

## Current state (as found)

- "What would you like to do?" is a `<select id=ddTasks>`, not a text box. It is built in `RenderDashboard()` ([dashboard.js:1974](../CMS/wwwroot/js/dashboard.js)) and handled by `ftnDDTasksOnChange()` (dashboard.js:38). Today it lists the wizards (`jsWizardALL` → only "Manage Exams") plus "Manage Dashboards".
  → **Plan:** add an **"Assign a Task…"** option (shown only to MGT-company users) that opens `PopUp('Assign Task')`. Existing options stay.
- Exams: the list comes from `_MGTGetExams {xcid}` and is opened with `viewMgtExam(ExamID, xcid, xcompany)`. That function is in `managementExamsNEW.js` (about 3.3k lines) and depends on the Documents page.
- Form Applications: `ViewDisp(0, FormID)` is already the "new record" path in `InteractiveForm.js` (line 1980 → `AddDisp()`).
- Dynamic Reports: upload → `NEO_GetDataFromExcel` → preview → `InsertDynamicReport` + `_InsertDynamicReports_v3` (`DynamicReports.js` ~900–1100). No template concept exists today.
- CMSMailbox items: `MBX_MessageItem.ItemType` is limited to File / FollowupAttachment / IAField / DRField / ExamFile / IAFormRecord. Every gate starts from an **existing** item (MainID).

## Design

### Data (new `CMSMailbox/sql/006_MBX_tasks.sql`, shared DB)
- `MBX_Task`: TaskID, MessageID, TaskType (`DynamicReport`/`Exam`/`FormApplication`), AssignedByUID, AssignedToUID, ExamID / xCID / FormID / ReportName / ReportType (whichever the type needs), TemplateHeaders, ResultID (ReportID or MainID once done), Status (`Open`/`Completed`), DueDate NULL, DTCreated, DTCompleted.
- `MBX_TaskTemplate`: TaskID, FileName, Bytes. Stores the Dynamic Report Excel template in its own table, so it does not depend on a CMS folder.
- `MBX_MessageItem.ItemType` gains `Task` (ItemID = TaskID).
- Procs: `MBX_CreateTask`, `MBX_GetTask` (only for the assignee or the assigner), `MBX_CompleteTask`, and `MBX_GetTaskCandidates @uid, @type, @key` (recipient picker filtered by real access, deduped to MGT accounts the same way `NEO_IAGetRecipients` does).

### CMS
- `dashboard.js`: new "Assign a Task…" option → `AssignTask(main)` popup with three tabs (Dynamic Report / Exams / Form Applications). After the user picks the item: filtered recipient picker, subject, message, optional due date.
- `MailboxShareController.cs`: new `SubmitMailboxTask` (multipart for the template). It calls `MBX_CreateTask` and reuses the existing notification email.
- Who can assign: MGT-company users only (their CID is `Tier=100` in `AccessTree`). Exact rule to be confirmed against `NEO_NewSECURITY`.

### CMSMailbox
- Message view shows a **task card** (type, item, due date, status, and a "Start" or "Open" button).
- **Form Application:** `ia-viewer.html` gets a new-record mode, `ViewDisp(0, FormID)`. New gate: the task belongs to the assignee **and** the Gate A form grant exists. Only the create/save actions are allowlisted. On first save, the new MainID is linked to the task's `IAFormRecord` item, so later opens use the existing gated path unchanged. **The task counts as Completed only once the record is released ("Save for Use")**, decided 2026-10-21 (sql/007). Until then it shows as "Saved", because the assigner can't open an unreleased record. Status is derived from the record's `DTReleased` when it's read, so a release done in CMSNEO counts too.
- **Dynamic Report** (built 2026-10-21, sql/008): CMS reads the template's headers with GemBox when the task is sent, and stores the file and headers on `MBX_Task`. The mailbox shows a "Download template" button, then an upload. `DRTaskController` serves the template. It passes the upload on to CMS's `main/MailboxDRTaskSubmit`, along with a one-off token minted for the assignee (the same pattern as `GetIAPDF`). CMS re-checks the open task and the assignee's Dynamic Reports permission. It then requires the template's headers (any order, ignoring case), applies the 500-row cap, and inserts the report as the assignee via `NEO_InsertDynamicReportLines_Bulk` + `_InsertDynamicReports_v3`. Finally `MBX_CompleteDRTask` marks the task complete. **Proxied rather than ported**, so there's one Excel parser and the GemBox license key stays out of the CMSMailbox repo. Assignee picker: the 'Dynamic Reports' user group or Global Admin, in the assigner's network.
- **Exam:** port-by-copy of the exam viewer (`managementExamsNEW.js` and its dependencies) into an `exam-viewer.html` host page, with a strict allowlist of `_Mgt*` exam procs. The gate is an Exam task for this assignee plus `AccessTreeDown(@uid)` for the exam's xcid (**not** `mgtCID`, per the earlier standing rule). This is the largest piece, similar in size to the IA viewer port.

## Changes after Phase 1 testing (2026-10-21)

- **Several tasks per message, one assignee.** The popup ("Assign Tasks...") builds a list of tasks, in any mix of Form Applications and Dynamic Reports (and Exams once they're built), and sends them as one message. The assignee picker (`main/GetTaskCandidates`) shows only people who have access to **every** task in the list, as the intersection of each task's own candidate list. `SubmitMailboxTask` validates every task, template and the assignee before writing anything. Each task is still its own message item plus its own `MBX_Task` row. In the mailbox, finishing one task refreshes only that task's card, so the other forms on the message keep any unsaved input.
- **Optional review step** (sql/009). There's a "Require my review" checkbox when sending, one setting for the whole message. When it's off, tasks complete as soon as they're finished, as before. When it's on, a finished task shows **Pending Review** until the assigner clicks **Mark as Completed** on it in their Sent folder in CMSMailbox (`MBX_ReviewTask`). "Finished" means a form record has been released, or a report has been uploaded (`dbo.MBX_TaskIsDone`). Pending Review isn't stored; it's derived when the message is read.
- **Dynamic Report viewer in the mailbox** (sql/010, `DRViewController`). A completed report opens on its task card for the assignee, in the assigner's Sent folder, and on replies (`MBX_SendReply` carries it as a `DynamicReport` item). It's a table of rows; clicking a row opens a panel with:
  - the row's values, **editable for the row's own company** (CMS's rule, re-checked by `NEO_DynamicRecordUpdate`),
  - notes, which can be shared with the other participants' companies,
  - attachments (upload, download, and delete your own).
  
  CMS's record procedures don't check access, so every request first passes `MBX_GetDRItemReport` (sender or recipient of the message) and `MBX_GetDRRowAccess` (the row is in that report and the row's company is in `AccessTreeDown(viewer)`). Deleting notes and attachments is limited to their creator. It's a purpose-built viewer, not a copy of CMS's 2,800-line Dynamic Reports code. Not included: adding or deleting rows, follow-ups, and action requests.
- The mailbox **Send Reply** button is disabled until the reply has text.
- **Mailbox alerts in CMS + one-time handoff** (sql/011, 012). `NEO_GetMyAlerts3` (CMS's own procedure behind Items Alerted On and the dashboard alert banner) now also lists the caller's mailbox messages, as Type "Secure Mailbox". Unread ones are under Not Viewed; once read they move to Viewed, with ViewedBy = [reader]. These are matched by email, so a management user switched into a downstream company still sees them. Clicking one calls CMS `main/MailboxHandoff`, which issues a **one-time code**: 256-bit random, valid 60 seconds, usable once, stored in `MBX_HandoffCode`. It opens the mailbox in a new tab with `?handoff=<code>`. The mailbox's `auth/handoff` exchanges the code for its normal login and strips it from the address bar, and the page sets `Referrer-Policy: no-referrer`. Nothing is bypassed: the mailbox login is the same NEO_Login + 2FA check the user already passed in CMS. Removing a mailbox alert uses MainID = -(1000000000 + MessageID), because `NEO_RemovedAlertedItems` is matched on MainID alone elsewhere. **Reusing the tab:** CMS always opens the mailbox in a tab named `cmsMailbox`. If that tab is already open, CMS posts the new code to it with `postMessage`, addressed to the mailbox's origin only. The mailbox accepts it only from CMS's origin (`auth/cms-origin`, taken from `CmsUrl`) and switches message in place. If the tab doesn't acknowledge within 1.5 seconds, CMS navigates it to the handoff URL instead.

## Phases
1. **Foundation + Form Application task:** SQL 006, the CMS popup and picker, the task card in the mailbox, and IA new-record mode. Delivers one complete task type from start to finish.
2. **Dynamic Report task.**
3. **Exam task** (the large port).
4. **Tracking:** an MGT task list in CMS, Sent-folder status, reminder emails if wanted.

## Needed / to check
- Proc definitions (look in `SQL_Repos` first): `NEO_MGTGetExams`, `NEO_IASubmitDataByGen300_2` (does it return the new MainID?), `NEO_InsertDynamicReports_v3`, `NEO_NewSECURITY` (MGT detection, DynamicReports/Exams flags), and the exam read/write procs the viewer uses.
- Confirm "Assign a Task…" as an option in the existing dropdown, rather than replacing the dropdown.
