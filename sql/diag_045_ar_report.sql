/*  diag_045 - why "This report couldn't be loaded" for an Action Request report in the mailbox (2026-11-18)
    Read-only. Run on QA, save results to SharedSQLWithClaude\Proof\diag_045.rpt  */

-- 1) What the mailbox logged for the last report opens (a "Denied" row = the access gate refused;
--    no row at all for the open = NEO_GetDynamicReportsALL2 itself failed)
select top 15 l.*, mi.ItemType, mi.ItemID
from MBX_AccessLog l
left join MBX_MessageItem mi on mi.MessageItemID = l.MessageItemID
where l.Detail like 'DR %'
order by 1 desc

-- 2) Recent Action Request items that point at a report, and for each person on the message:
--    are they let in, do they have the report's type, how many rows they can see
;with items as (
    select top 5 mi.MessageItemID, mi.MessageID, mi.ItemID MainID, dbo.MBX_ItemReportID(mi.MessageItemID) ReportID
    from MBX_MessageItem mi
    where mi.ItemType = 'IAFormRecord' and dbo.MBX_ItemReportID(mi.MessageItemID) is not null
    order by mi.MessageItemID desc
), people as (
    select i.*, m.FromUID UID, 'sender' Role from items i join MBX_Message m on m.MessageID = i.MessageID
    union all
    select i.*, r.ToUID, 'recipient' from items i join MBX_Recipient r on r.MessageID = i.MessageID
)
select p.MessageItemID, p.MainID, p.ReportID, p.Role, p.UID, u.Fname + ' ' + u.Lname Name, dbo.mycid(p.UID) CID,
    rt.Type ReportType,
    dbo.ftnDRFullAccess(p.UID) DRFullAccess,
    case when exists (select 1 from dbo.ftnDRTeamTypes(p.UID) t where t.TypeName = rt.Type) then 1 else 0 end HasTypeByTeam,
    (select count(*) from NEO_DynamicReports dr
        join AccessTreeDown(p.UID) atd on atd.CID = dbo.mycid(dr.CreatedBy) and atd.Down = 1
        where dr.ReportID = p.ReportID and dr.active = 1) RowsInAccessTree
from people p
join Users u on u.UID = p.UID
outer apply (select top 1 Type from NEO_DynamicReports where ReportID = p.ReportID and active = 1) rt
order by p.MessageItemID desc, p.Role
