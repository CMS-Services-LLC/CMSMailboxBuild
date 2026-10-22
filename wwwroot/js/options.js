//log update 20260113-802am-jk
// Grab-bag of shared "options"-style popups and page utilities: file history/notes, latest-updates
// blog, support requests, site administration, file upload, and the file-hover preview tooltip.
var arrOpts = [];
var optsOpen = false;
var whichOpt;
var arrMonths = ["", "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
var jsSelectedFileNotes = [];
var jsCurrentLicenseReport = [];


// ============================================================
// SECTION: file history view, file notes (add/edit/delete/view)
// ============================================================
function FileHistory(main, fid) {
    main.appendChild(dyn("div", "id=divFileHistory"));
    buildFileHistory("divFileHistory", fid);
}

function ViewFileHistory(main, fidDyn) {
    var fid = fidDyn[0];
    var dyn = fidDyn[1];
    var x = document.getElementById(main.id.replace("_Contents", ""));
    var ix = main.id.split("_")[1];

    xsection(main, ["div|class=sm pad10|Please wait while the history is loading ..."]);
    getData(null, newFormData("_GetFileHistory", { fid: fid, dyn: dyn }), function (vr) {
        var js = jparse(vr);
        var contentWindow = document.getElementById(main.id);
        main.innerHTML = "";
        console.log("err 25", js, fidDyn, { fid: fid, dyn: dyn });
        for (var i = 0; i < js.length; i++) {
            js[i].Action_Taken_By = js[i].Action_Taken_By.replace("@", " with ");
            js[i].ActionDT = js[i].Action_Date;

        }
        //"Action_Taken_By", "Action", "Action_Date"
        //getGChartTable(js, ["Action_Taken_By", "Action", "Action_Date"], contentWindow,
        //    [{ Func: "ViewFileHistory_onclick", Cols: [0], Params: ["FID", "Filename", "*null", "*PopUp_" + ix, "*null", "*nooptions", "eventid"] }],
        //    null, null, null, null, ["ActionDT", true]);

        njchart(js, ["Action_Taken_By", "Action", "Action_Date"], contentWindow, vfh_click, null, "DT", true, ix)

    });
}

function vfh_click(xx, rowix, fld, ix) {
    var rtn = {class:"cursor"};
    if (xx.clickAction) {
        if (xx.clickAction == "attachment")
            rtn.click = "ViewDRFile(" + xx.FID + ",'" + xx.Filename + "')";

        else if (xx.clickAction == "dynamic")
            rtn.click = "reportLoadFiles(" + xx.FID + ",'" + xx.Filename + "','Dynamic', true)";

        else if (xx.clickAction == "standard")
            rtn.click = "reportLoadFiles(" + xx.FID + ",'" + xx.Filename + "','main', true)";

        else if (xx.clickAction == "notes")
            rtn.click = "PopUp('View File Notes', " + xx.FID + ", null, null, ['300px', '600px'])"; //, 'PopUp_" + ix + "')";

        else
            rtn.class = "";
    } else {
        //rtn.click = "ViewFileHistory_onclick(" + xx.FID + ",'" + xx.Filename + "',null,'PopUp_" + ix + "',null,'nooptions','" + xx.eventid + "')";
        rtn.class = "";
    }

    return rtn;
}

function ViewFileHistory_onclick(fid, filename, aaa, pu, bbb, ccc, ev) {
    if (!ev)
        ViewFile(fid, filename, aaa, pu, bbb, ccc)
    else
        manageFileOptions([fid, ev], 'openremediation');
}

function AddFileNote(main, fid, go) {
    if (!go) {
        var id = main.id.split("_")[1];
        var opts = main.id.replace("_Contents", "_Opts");
        main.parentElement.style.zIndex = 10000;

        nsection(opts, [
            "label|class=padLeft10|",
            "button|class=blueButton|onclick=AddFileNote(null, " + fid + ", true)|Submit"
        ]);
        document.getElementById("btnPopUpClose_" + id).innerHTML = "<l>Cancel</l>";

        nsection(main.id, [
            "textarea|id=txtAddFileNote|style=width:100%;height:200px; resize:none|",
            "div|class=smhdr|Share with:",
            "div|class=pad10|id=dvAddNoteShareWith|style=height:100px; overflow-y:scroll"
        ]);
        txtAddFileNote.focus();

        getData(null, newFormData("_GetAllowedCompanies", { fid: fid }), function (vr) {
            var js = jparse(vr);
            c_log(vr);
            if (js.length == 0) {
                nsection("dvAddNoteShareWith", ["div|class=sm pad10|This file is not available to any network companies"]);
            }
            for (var i = 0; i < js.length; i++) {
                if (js[i].Company != null) {
                    nsection("dvAddNoteShareWith", [
                        "label|style=width:20px|",
                        "input|type=checkbox|name=txtFileNote_ShareWith|id=txtFileNote_ShareWith_" + i +
                        "|onclick=cbMultiSelect(event, 'txtFileNote_ShareWith'," + i + ")|value=" + js[i]["CID"],
                        "label|class=sm padLeft10|for=id=txtFileNote_ShareWith_" + i + "|" + js[i]["Company"],
                        "br"
                    ]);
                }
            }
        });
    } else {
        var note = txtAddFileNote.value;
        var shares = document.getElementsByName("txtFileNote_ShareWith");
        var arrShares = [];
        for (var i = 0; i < shares.length; i++) {
            if (shares[i].checked) {arrShares.push(shares[i].value)}
        }
        var data = newFormData("_InsUpdDelFileNotes", { type: "I", fid: fid, nid: "", Note: note, xCIDs: arrShares.join(",") });
        getData(null, data, function (vr) {
            closePopUp("Add File Note");
            renewPopUp("View File Notes")
            renewPopUp("Dynamic Record Options");   

            nid = jparse(vr)[0].NID;
            if (nid)
                SendEmailAlert("File Notes", nid);

            getData(null, newFormData("_GetCacheFiles", {}), function (vr) {
                var tmpFiles = jparse(vr);
                jsOFiles = tmpFiles;
                if (!jsSECURITY.filter(d => d.Action == "Document Management")[0].Assigned) {
                    jsOFiles = [];
                };
            })
        });
    }
}

function DeleteFileNote(NID, go) {
    if (!go) {
        xconfirm("Are you sure you want to delete this note?", null, "DeleteFileNote('" + NID + "', true)");
    } else {
        var js = jsSelectedFileNotes.filter(d => d.NID == NID)[0];
        var FID = js["FID"];
        var data = newFormData("_InsUpdDelFileNotes", { type: "D", fid: FID, nid: NID, Note: "", xCIDs: "" });
        getData(null, data, function (vr) {
            xconfirm();
            PopUp("Edit File Note");
            renewPopUp("View File Notes")
        });
    }
}
function EFN(NID, mainidID, CreatedByCID) {
    if (CreatedByCID == myCID) {
        var js = jsSelectedFileNotes.filter(d => d.N_ID == NID)[0];
        var arr = [js["FID"], js["NID"]];
        PopUp("Edit File Note", arr, null, null, ['400px', '600px']); //, "PopUp_" + mainidID);
    } else {
        xconfirm("You do not have permission to edit this note");
    }
}



function EditFileNote(main, arr, go) {
    if (!go) {
        var fid = arr[0];
        var nid = arr[1];
        xsection(main, ["div|class=pad10 sm|Please wait while data is loading ..."]);
        var topMain = document.getElementById("PopUp_" + main.id.split("_")[1]);
        //topMain.style.top = "-100px";
        

        RunMultiSP("_GetFileNotes,_GetAllowedCompanies", [{ fid: fid }, { fid: fid }], function (vr) {
            main.innerHTML = "";

            var js = vr[0].filter(d => d.NID == nid);
            var jsAllowedCompanies = vr[1];
            var arrSW = [];
            for (var i = 0; i < js.length; i++) {
                if (js[i]["Shared_With"] != "") { arrSW.push(js[i]["Shared_With"]) }
            }
            js = js[0];
            var note = js["Note"];

            var id = main.id.split("_")[1];
            var opts = main.id.replace("_Contents", "_Opts");
            nsection(opts, [
                "label|class=padLeft10|",
                "button|class=blueButton|onclick=EditFileNote(null, [" + fid + ",'" + nid + "'], true)|Submit",
                "label|class=padLeft10|",
                "button|class=blueButton|onclick=DeleteFileNote('" + nid + "')|Delete"
            ]);
            document.getElementById("btnPopUpClose_" + id).innerHTML = "<l>Cancel</l>";

            xsection(main, [
                "input|type=hidden|id=txtEditFileNoteNID|value=" + nid,
                "textarea|id=txtEditFileNote|style=width:100%;height:200px; resize:none|" + note,
                "div|class=smhdr|Share with:",
                "div|class=pad10|id=dvAddNoteShareWith|style=height:100px;overflow-y:scroll"
            ]);
            txtEditFileNote.focus();

            //getData(null, newFormData("_GetAllowedCompanies", { fid: fid }), function (vr) {
                var js = jsAllowedCompanies;
                if (js.length == 0) {
                    nsection("dvAddNoteShareWith", ["div|class=sm pad10|This file is not available to any network companies"]);
                }
                for (var i = 0; i < js.length; i++) {
                    nsection("dvAddNoteShareWith", [
                        "label|style=width:20px|",
                        "input|type=checkbox|name=txtFileNote_ShareWith|id=txtFileNote_ShareWith_" + i +
                        "|onclick=cbMultiSelect(event, 'txtFileNote_ShareWith'," + i + ")|value=" + js[i]["CID"],
                        "label|class=sm padLeft10|for=id=txtFileNote_ShareWith_" + i + "|" + js[i]["Company"],
                        "br"
                    ]);
                    if (arrSW.indexOf(js[i]["Company"]) > -1) { document.getElementById("txtFileNote_ShareWith_" + i).checked = true;}
                }
            //});
        });
    } else {
        var fid = arr[0];
        var nid = arr[1];
        var note = txtEditFileNote.value;
        var shares = document.getElementsByName("txtFileNote_ShareWith");
        var arrShares = [];
        for (var i = 0; i < shares.length; i++) {
            if (shares[i].checked) { arrShares.push(shares[i].value) }
        }
        c_log({ type: "U", fid: fid, nid: nid, Note: note, xCIDs: arrShares.join(",") });

        var data = newFormData("_InsUpdDelFileNotes", { type: "U", fid: fid, nid: nid, Note: note, xCIDs: arrShares.join(",") });
        getData(null, data, function (vr) {
            PopUp("Edit File Note");
            renewPopUp("View File Notes");
        });
    }
}

function ViewFileNotes(main, fid) {
    var puix;
    if (jsPopUps.filter(d => d.Title == "File Options").length > 0) {
        puix = "'PopUp_" + jsPopUps.filter(d => d.Title == "File Options")[0]["ix"] + "'";
    }
    var id = main.id.split("_")[1];
    var opts = main.id.replace("_Contents", "_Opts");
    nsection(opts, [
        "label|class=padLeft10|",
        "button|class=blueButton|onclick=PopUp('Add File Note', " + fid + ", null, null, ['400px','600px'])|Add Note"
    ]);



    getData(null, newFormData("_GetFileNotes", { fid: fid }), function (vr) {
        var js = jparse(vr);
        jsSelectedFileNotes = js;

        if (js.length == 0) {
            nsection(main.id, ["div|class=sm pad10|There are no notes added to this file"]);
        } else {
            var obj = getFileNotesJS(js);
            getGChartTable(obj, ["Note", "Created_By", "Shared_With", "Date_Created"], main, [{ Func: "EFN", Cols: [0], Params: ["N_ID", "*" + id, "CreatedByCID"] }],
                null, null, null, null, ["Date_Created", true]);
        }
    });
}

function getFileNotesJS(js) {
    var obj = [];
    for (var i = 0; i < js.length; i++) {
        var NID = js[i]["NID"];
        var Shared_With = js[i]["Shared_With"];
        var note = js[i]["Note"].replace(/\n/g, " ");
        note = (note.length > 100) ? note.substring(0, 99) + "..." : note;
        js[i]["Note"] = note;

        if (obj.findIndex(d => d.NID == NID) == -1) {
            obj.push(js[i]);
            var ix = obj.length - 1;
            //obj[ix]["Shared_With"] = "";
            var xx = js.filter(d => d.NID == NID);
            c_log(xx);
            var arrSW = [];
            for (var ii = 0; ii < xx.length; ii++) {
                if (xx[ii]["Shared_With"] != "") {
                    var sw = xx[ii]["Shared_With"];
                    sw = (sw.length > 20) ? sw.substring(0, 19) + "..." : sw;
                    arrSW.push("[" + sw + "]");
                }
            }
            c_log(arrSW);
            obj[ix]["Shared_With"] = arrSW.join(", ");
        }

    }
    return obj;
}

// ============================================================
// SECTION: latest-updates blog editor, support request form, calendar popup
// ============================================================
function SelectUploadAttachments(mainid, js) {
    xconfirm();
    var elems = ["div|class=smhdr|Select the following files from the file browser and click continue:", "hr"];

    var displayedAttachments = [];
    for (var i = 0; i < js.length; i++) {
        if (displayedAttachments.indexOf(js[i]["Attachments"]) == -1 && js[i]["Attachments"] != null) {
            elems.push("div|style=padding-left:30px|" + js[i]["Attachments"]);
        }
        displayedAttachments.push(js[i]["Attachments"]);
    }

    section("optMain", elems);
}

function EditLatestUpdates(main) {
    main.appendChild(dyn("div", "id=blog",
        dyn("div", "id=box_hdr|class=shadowSection smhdr|",
            dyn("table", "id=blog_hdr_table"))));
    section("blog_hdr_table", [
        "tr",
        "td|Header:",
        "td|id=blog_hdrTD_0",
        "tr",
        "td|Message:",
        "td|id=blog_msgTD_0",
        "tr",
        "td|id=blog_btnTD_0|colspan=2|style=text-align:right"
    ]);

    blog_hdrTD_0.appendChild(dyn("textarea", "id=blog_header_0|style=height:30px; width:500px"));
    blog_msgTD_0.appendChild(dyn("textarea", "id=blog_msg_0|style=height:30px; width:500px"));
    blog_btnTD_0.appendChild(dyn("button", "class=blueButton|onclick=updateBlog(0)|Add"));

    blog.appendChild(dyn("div", "id=blog_inner|style=height:330px;overflow-y:scroll"));

    var data = newFormData("GetBlog", {});
    getData("#adHoc", data, function (vr) {
        var js = jparse(vr);
        c_log(js);
        if (js.length > 0) {
            
            var elems = [];
            for (var i = 0; i < js.length; i++) {
                if (i > 0) {
                    elems.push("hr");
                }
                elems.push("br");
                elems.push("textarea|id=blog_header_" + js[i]["id"] + "|style=height:30px; width:600px|innerHTML=" + js[i]["Header"]);

                elems.push("br");
                elems.push("textarea|id=blog_msg_" + js[i]["id"] + "|style=height:30px; width:600px|innerHTML=" + js[i]["Msg"]);

                elems.push("br");
                elems.push("div|class=sm|style=padding-left:25px|[ " + js[i]["username"] + " - " + js[i]["DTCreated"] + " ]");
                elems.push("button|class=blueButton|onclick=updateBlog(" + js[i]["id"] + ")|Update");
                elems.push("label|style=width:10px;");
                elems.push("button|class=blueButton|onclick=updateBlog(" + js[i]["id"] + ", 1)|Delete");
            }

            section("blog_inner", elems);
        }
    })
}

function updateBlog(id, del) {
    if (del == null) { del = 0;}
    var hdr = document.getElementById("blog_header_" + id).value;
    var msg = document.getElementById("blog_msg_" + id).value;
    var data = newFormData("UpdateBlog", { Header: hdr, Msg: msg, id: id, del: del });

    getData("#adHoc", data, function (vr) {
        opts(false);
        showOpts("Edit Latest Updates", null, null, true);
    })
}

function SmartReplace(main) {
    main.appendChild(dyn("div", "id=smartReplaceInner"));
    section("smartReplaceInner", [
        "p|This feature allows you to quickly replace any expired documents in the Licensing section with the newest license for that state.",
        "p|You should first upload all of your new licenses into CMS.  Once they are in the system, each one that you have uploaded (and is not expired) will replace the previous expired version.",
        "p|style=color:red|If you keep multiple licenses per state, you should NOT use this function.",
        "p",
        "button|class=blueButton|onclick=smartReplaceGo()|Smart Replace"
    ]);
}
function smartReplaceGo() {
    var data = newFormData("SmartReplaceLicences", {});
    getData("#adHoc", data, function (vr) {
        reloadExplorer();
    });
}

function LatestUpdates(main) {
    section("optMain", [
        "div|class=shadowSection",
        "iframe|title=LatestUpdates|src=CMSLatestUpdates.html|style=background-color:white;width:100%;height:95%"
    ]);
}

function SendSupportRequest(main) {
    section("soSubmit", [
        "button|class=ugSubmitBtn|onclick=SendSupportRequestGO()|Submit"
    ]);
    section("optMain", [
        "div|id=supportTopline| ",
        "textarea|id=supportMessage|style=width:100%;height:90%; resize:none|"
    ]);

    section("supportTopline", ["select|style=float:right|id=supportSection", "div|Provide your details below and then click \"Submit\"."]);

    var sections = ["Dashboard", "Our Documents", "3rd Party Management", "Form Applications", "Form App Management"];
    var elems = [];
    var slctd = 0
    for (var i = 0; i < sections.length; i++) {
        slctd = (sections[i] == sectionTitle) ? i : slctd;
        elems.push("option|value=" + sections[i] + "|" + sections[i]);
    }
    section("supportSection", elems);
    supportSection.selectedIndex = slctd;
    c_log(sectionTitle);
}

function SendSupportRequestGO() {
    var msg = supportMessage.value.replace(/\n/g, "<br>");
    msg = "<p>Section:" + supportSection.value + "</p>" + msg;

    var data = new FormData();
    data.append("strjson", jstring({ msg: msg }));

    getData("#Support", data, function (vr) {
        xconfirm(vr);
        opts(false);
    })
}

function Calendar(main, extra) {
    opts(false);
    //window.open("Calendar", "_blank", "height=500px, width=900px");
    //window.open("Calendar");
    windowLoad("Calendar", null, true);
}


function xCalendar(main, extra) {
    var sm = 0, sy = 0, ey = 0;
    if (extra != null) {
        sm = extra[0];
        sy = extra[1];
        ey = extra[2];
    }
    if (ey == 0) {
        section("soSubmit", [
            "label|class=blueButton|onclick=opts(false); showOpts('Calendar', [" + sm + "," + sy + ",1], '[by Year]', true)|View by Year"
        ]);
    } else {
        section("soSubmit", [
            "label|class=blueButton|onclick=opts(false); showOpts('Calendar', null, '[by Month]', true)|View by Month"
        ]);
    }
    var saveSM = sm, saveSY = sy;

    var data = newFormData("GetCalendar", { slctMonth: sm, slctYear: sy, exportAll: ey });

    getData("#adHoc", data, function (vr) {
        var js = jparse(vr);
        sm = js[0]["slctMonth"];
        sy = js[0]["slctYear"];

        optWindow_extrahdr.appendChild(dyn("div", "id=Calendar_inner|class=shadowSection"));

        if (ey == 1) {
            section("Calendar_inner", [
                "label|class=blueButton|style=font-weight:bold;|onclick=opts(false); showOpts('Calendar', [1, " + (sy - 1) + ",1], '[by Year]', true)|Previous",
                "label|style=width:200px;text-align:center;font-weight:bold|Year " + sy,
                "label|class=blueButton|style=font-weight:bold;|onclick=opts(false); showOpts('Calendar', [1," + (sy + 1) + ",1], '[by Year]', true)|Next"
            ]);
        } else {
            section("Calendar_inner", [
                "label|class=blueButton|style=font-weight:bold;|onclick=opts(false); showOpts('Calendar', [" + (((sm - 1) == 0) ? 12 : (sm - 1)) + "," + (((sm - 1) == 0) ? (sy - 1) : sy) + ",0], '[by Month]', true)|Previous",
                "label|style=width:200px;text-align:center;font-weight:bold|" + arrMonths[sm] + " " + sy,
                "label|class=blueButton|style=font-weight:bold;|onclick=opts(false); showOpts('Calendar', [" + (((sm + 1) == 13) ? 1 : (sm + 1)) + "," + (((sm + 1) == 13) ? (sy + 1) : sy) + ",0], '[by Month]', true)|Next"
            ]);
        }
        optWindow_extrahdr.style.display = "";
        main.style.height = "380px";

        var elems = [], xelems = [];
        if (js[0]["itemID"] == null) {
            elems.push("div|style=padding-top:10px; padding:30px|There are no events listed for this month");
        }
        for (var i = 0; i < js.length; i++) {
            if (js[i]["itemID"] != null) {
                var dt = js[i]["itemDT"].split("T")[0];
                elems.push("div|style=padding-top:10px|icon:li|" + dt + " - [" + js[i]["itemType"] + "] " + js[i]["itemDescr"]);
                xelems.push(dt + " - [" + js[i]["itemType"] + "] " + js[i]["itemDescr"] + "\n");
            }
        }
        section("optMain", elems);

        if (ey == 1 && 1 == 2) {
            xconfirm(null, ["textarea|id=xcon|style=width:100%;height:270px","div|class=sm|style=color:red|Text has been copied to your clipboard."]);

            for (var i = 0; i < xelems.length; i++) {
                xcon.innerHTML = xcon.innerHTML + xelems[i];
            }

            var txt = document.getElementById("xcon");
            txt.select();
            document.execCommand("copy");
            //alert("Text has been copied.");

            opts(false); showOpts("Calendar", [saveSM, saveSY, 0]);
        }
    });

    


    //opt.style.height = "600px";
    //main.appendChild(dyn("div", "id=showcase-wrapper|style=height:260px",
    //    dyn("div", "id=myCalendarWrapper|style=height:260px")));

    ////main.appendChild(dyn("div", "id=example",
    ////    dyn("h3", "innerHTML=currentValue:",
    ////        dyn("p", "id=current-date"))));

    ////example.appendChild(dyn("h3", "innerHTML=currentValue.getDay():",
    ////    dyn("p", "id=current-day")));

    ////example.appendChild(dyn("h3", "innerHTML=currentValue.toDateSring():",
    ////    dyn("p", "id=current-datestring")));

    ////-----------------------------------------------------------------------------------------

    //const nextYear = new Date().getFullYear() + 1;
    //const myCalender = new CalendarPicker('#myCalendarWrapper', {
    //    // If max < min or min > max then the only available day will be today.
    //    min: new Date(),
    //    max: new Date(nextYear, 10) // NOTE: new Date(nextYear, 10) is "Sun Nov 01 <nextYear>"
    //});

    //const currentDateElement = document.getElementById('current-date');
    ////currentDateElement.textContent = myCalender.value;

    //const currentDayElement = document.getElementById('current-day');
    ////currentDayElement.textContent = myCalender.value.getDay();

    //const currentToDateString = document.getElementById('current-datestring');
    ////currentToDateString.textContent = myCalender.value.toDateString();

    //myCalender.onValueChange((currentValue) => {
    //    currentDateElement.textContent = currentValue;
    //    currentDayElement.textContent = currentValue.getDay();
    //    currentToDateString.textContent = currentValue.toDateString();

    //    c_log(`The current value of the calendar is: ${currentValue}`);
    //});

}

/* UNUSED — verified zero call sites anywhere in the active codebase.
function xViewFile(main, fid) {
    main.appendChild(dyn("iframe", "style=height:" + (document.body.scrollHeight * .4) + "px; width:100%|src=Download?fid~" + fid));
}
*/



/* UNUSED — verified zero call sites anywhere in the active codebase (the "xxxx" prefix matches this
   codebase's convention for intentionally-disabled functions).
function xxxxManageFolders(main) {
    main.appendChild(dyn("div", "id=manageFolders_inner"));
    section("manageFolders_inner", [
        "div|class=bluelink|icon=li|onclick=showOpts('Folder Sharing')|Set FOLDER sharing", "br",
        "div|class=bluelink|icon=li|onclick=showOpts('File Sharing')|Set FILE sharing", "br",
        "div|class=bluelink|icon=li|onclick=showOpts('Manage Folders and Labels')|Add/Edit Folders and Labels", "br",
    ]);
}
*/

// ============================================================
// SECTION: site administration search/select, file upload, bulk-upload launchers
// ============================================================
function selectSiteAdmin(u) {
    getData("#getChangeLogins", null, function (vr) {
        var js = jsSiteAdmin.filter(d => d.uid == u);
        var data = new FormData();

        var strjson = {};
        strjson["uid"] = js[0]["uid"];
        strjson["cid"] = js[0]["cid"];
        strjson["username"] = js[0]["username"];
        strjson["company"] = js[0]["company"];

        data.append("strjson", jstring(strjson));

        getData("#changeLogin", data, function (vr) {
            c_log(vr);
            if (vr == "reload") {
                document.location.reload();
            }
        });
    });
    
}


function searchSiteAdmin() {
    var str = strSearchSiteAdmin.value.toLowerCase();
    var js = jsSiteAdmin.filter(d =>
        d.company.toLowerCase().indexOf(str) == 0 ||
        d.fname.toLowerCase().indexOf(str) == 0 ||
        d.lname.toLowerCase().indexOf(str) == 0 ||
        d.username.toLowerCase().indexOf(str) == 0 
    );

    var elems = [];
    for (var i = 0; i < js.length; i++) {
        elems.push("div|class=alink|onclick=selectSiteAdmin(" + js[i]["uid"] + ")|innerHTML=" + js[i]["username"]);
    }
    siteadmin.innerHTML = "";
    section("siteadmin", elems);
}
function SiteAdministration(main) {
    main.appendChild(dyn("div", "id=searchsiteadmin"));
    main.appendChild(dyn("div", "style=height:48vh; overflow-y:scroll|id=siteadmin"));

    section("searchsiteadmin", [
        "label|Search by User or Company: ",
        "label|style=width:10px",
        "input|id=strSearchSiteAdmin|placeholder=Showing All|onkeyup=searchSiteAdmin()",
        "hr"
    ]);
    strSearchSiteAdmin.focus();

    searchSiteAdmin();
}

function FileUpload(main, fil) {
    xconfirm();
    replaceFILE = null;
    innerReplaceFile = { replaceFILE: [], replaceWITH: [] };
    opt.style.zIndex = 3000;

    if (fil != null) {
        try {
            var ix = jsFileLines.findIndex(d => d.fid == fil);
            if (ix > -1) {
                replaceFILE = [fil.toString(), jsFileLines[ix]["filename"]];
            }
        } catch (e) {}
    }

    myfile.value = null;
    selectedFolder = null;
    uploadExpandClassVals = jparse("[]");

    if (fil == null) {
        //main.appendChild(dyn("div", "class=shadowSection|innerHTML=Select file(s) to upload ..."));
    } else {
        main.appendChild(
            dyn("div", "class=shadowSection|innerHTML=Select replacement file for [ ",
                dyn("b", "ihtml=" + replaceFILE[1],
                    dyn("L", "ihtml= ]"))));
    }
    c_log(replaceFILE);

    
    if (replaceFILE == null) {
        main.appendChild(dyn("div", "style=padding:10px",
            dyn("label", "id=fileUpload|class=longblueButton|onclick=showOpts('File Upload Directory', true, null, true, 'reloadExplorer(function(){selectMainWindow(\"File Explorer\")})')|innerHTML=Drag & Drop Files to Document View")));

    } else {
        main.appendChild(dyn("div", "style=padding:10px",
            dyn("label", "id=fileUpload|class=longblueButton|onclick=myfile.click()|innerHTML=Browse File(s) from your computer")));

        main.appendChild(dyn("div", "style=padding:10px",
            dyn("label", "id=fileUpload|class=longblueButton|onclick=showOpts('File Upload Directory')|innerHTML=Select a previously uploaded file to replace this one")));
    }

    if (selectedXCID == null) {
        main.appendChild(dyn("div", "style=padding:10px",
            dyn("label", "id=fileUpload|class=longblueButton|onclick=showOpts('Smart Replace')|innerHTML=Licensing Smart Replace")));
    }

    
    //section("soSubmit", ["label|class=blueButton|onclick=showOpts('File Upload Directory')|innerHTML=Submit"]);
}

function ComplaintsBulkUpload(main) {
    main.appendChild(dyn("div", "id=cdUpload"));

    section("cdUpload", [
        "div|Step 1: Select \"Tab\" delimited file with the first row containing headers.",
        "br",
        "label|id=fileUpload|class=blueButton|onclick=bulkUploadFile.click()|innerHTML=Browse File(s)"
    ]);
}
function DisputesBulkUpload(main) {
    main.appendChild(dyn("div", "id=cdUpload"));

    section("cdUpload", [
        "div|Step 1: Select \"Tab\" delimited file with the first row containing headers.",
        "br",
        "label|id=fileUpload|class=blueButton|onclick=bulkUploadFile.click()|innerHTML=Browse File(s)"
    ]);
}

//**************************************************************************

function xgetData() {
    c_log("ajax command was disabled");
}
// ============================================================
// SECTION: generic options popup shell (showOpts/opts/popOut), date-status helper, file-hover tooltip
// ============================================================
function showOpts(wo, xtra, appendTitle, scroll, closeFunc) {
    if (optsOpen && whichOpt == wo) {
        opts(false);
    } else {
        opt.style.height = "500px";
        opt.style.width = "60%";
        opt.style.zIndex = "2500";

        var displayWO = wo;
        if (wo == "Calendar") {
            if (xtra == null) {
                displayWO = "Monthly Calendar";
            } else {
                if (xtra[2] == 0) {
                    displayWO = "Monthly Calendar";
                } else {
                    displayWO = "Yearly Calendar";
                }
            }
            appendTitle = null;
        }

        opts(true);
        whichOpt = wo;
        opt.appendChild(
            dyn("div",
                "id=optWindow_hdr|class=shadowSection hdr|style=position:relative|innerHTML=" + displayWO + "&nbsp;"));
        section("optWindow_hdr", [
            ((appendTitle == null) ? "" : "label|id=optWindow_hdr_appendTitle| - " + appendTitle),
            "label|id=showOptsHeaderOpts|class=excludePrint|style=float:right"
        ]);

        document.getElementById("optWindow_hdr").style.backgroundColor = "rgb(31, 41, 67)";
        document.getElementById("optWindow_hdr").style.color = "white";
        document.getElementById("optWindow_hdr").style.height = "50px";
        document.getElementById("optWindow_hdr").style.borderRadius = "5px";
        dragElement(opt);
        opt.style.height = "500px";

        opt.appendChild(dyn("div", "id=optWindow_extrahdr|class=shadowSection|style=display:none"));
        

        section("showOptsHeaderOpts", [
            "label|class=excludePrint|style=float:right;padding-right:10px|id=soSubmit",
            "label|style=padding-left:10px",
            "label|class=ugCancelBtn excludePrint|onclick=" + ((closeFunc != null) ? closeFunc : "clrSubmit(); showOpts('" + wo + "')") + "|innerHTML=Close",
            "label|style=padding-left:10px",
            "img|style=float:right; display:none; cursor:pointer;width:25px;height:25px|src=popout.png|onclick=popOut('" + wo + "', " + ((xtra != null) ? "'" + xtra + "'" : "") + ")"
        ]);

       

        //c_log(opt.clientHeight);
        var ht = opt.clientHeight - 60;
        var main = dyn("div", "id=optMain|style=width:100%;height:" + ht + "px;position:relative;padding:10px;");
        opt.appendChild(main);
        //c_log("about to launch function");
        //c_log(wo);
        //c_log(scroll);
        c_log(wo);
        window[wo.replace(/ /g, "")](main, xtra);

        if (scroll) { main.style.overflowY = "scroll" }
        else { main.style.overflowY = "";}
    }
}

function popOut(main, xtra) {

    window.open("Popout?main=" + main + "&var=" + xtra, "", "width=" + opt.offsetWidth + ", height=" + opt.offsetHeight);
}

function doPopOut(wo, xtra) {
    opt.innerHTML = "";
    opt.style.display = "";

    whichOpt = wo;
    opt.appendChild(
        dyn("div", "id=showOptsHeader|class=shadowSection hdr", //|innerHTML=" + wo,
            dyn("label", "style=float:right", dyn("label", "class=blueButton|onclick=window.close()|innerHTML=Close")
            )));

    section("showOptsHeader", [
        "label|id=showOptsHeader_txt|" + wo,
        "label|style=float:right;padding-right:10px|id=soSubmit"
    ]);

    var main = dyn("div", "id=optMain|style=padding:10px;");
    opt.appendChild(main);
    wo = wo.replace(/ /g, "");
    try {
        window[wo](main, xtra);
    } catch (ex) {
        c_log(ex);
        c_log("err" + xtra);
    }
}

function clrSubmit() {
    document.getElementById("soSubmit").innerHTML = "";
}

var optsFunc = null;
function opts(closeOpen) {
    document.getElementById("PageContainer").style.opacity = (!closeOpen) ? "1" : ".3";
    document.getElementById("optWindow").style.opacity = (!closeOpen) ? "1" : ".6";
    opt.style.opacity = "1";

    optsOpen = closeOpen;
    opt.innerHTML = "";
    opt.style.display = (optsOpen) ? "" : "none";
    if (optsFunc != null) {
        window[optsFunc]();
    }
}


//function getDateStatus(dt) {
//    console.log(dt);
//    var expDT = new Date(dt);
//    var thisDT = new Date();
//    var DTPlus60 = new Date();
//    DTPlus60.setDate(thisDT.getDate() + 60);

//    var bclrs = ["white", "white", "yellow", "red"];
//    var fclrs = ["black", "black", "black", "white"];
//    var status = 0;
//    status = (["exempt", "perpetual"].indexOf(dt.toLowerCase()) > -1) ? 0 : (dt == "") ? 0 : (dt == null) ? 0 : (expDT > DTPlus60) ? 1 : (expDT > thisDT) ? 2 : 3;

//    return { Status: status, bclr: bclrs[status], fclr: fclrs[status] };
//}

//function getDateStatus(dt) {
//   // console.log(dt);

//    // Default values if dt is invalid or null
//    if (dt == null || dt === "") {
//        return { Status: 0, bclr: "white", fclr: "black" };
//    }

//    // Safe lowercase conversion
//    var lower = (typeof dt === "string") ? dt.toLowerCase() : "";

//    var expDT = new Date(dt);
//    var thisDT = new Date();
//    var DTPlus60 = new Date();
//    DTPlus60.setDate(thisDT.getDate() + 60);

//    var bclrs = ["white", "white", "yellow", "red"];
//    var fclrs = ["black", "black", "black", "white"];

//    var status = 0;

//    if (["exempt", "perpetual"].includes(lower)) {
//        status = 0;
//    } else if (isNaN(expDT.getTime())) {
//        // Invalid date string
//        status = 0;
//    } else if (expDT > DTPlus60) {
//        status = 1;
//    } else if (expDT > thisDT) {
//        status = 2;
//    } else {
//        status = 3;
//    }

//    return { Status: status, bclr: bclrs[status], fclr: fclrs[status] };
//}

function getDateStatus(dt) {
    //console.log("getDateStatus:", dt);

    var bclrs = ["white", "white", "yellow", "red"];
    var fclrs = ["black", "black", "black", "white"];
    var status = 0;

    //Handle null, undefined, or empty values early
    if (dt == null || dt === "") {
        return { Status: 0, bclr: bclrs[0], fclr: fclrs[0] };
    }

    //Normalize string input
    var lower = (typeof dt === "string") ? dt.trim().toLowerCase() : "";

    //Handle Exempt / Perpetual cases directly
    if (["exempt", "perpetual"].includes(lower)) {
        return { Status: 0, bclr: bclrs[0], fclr: fclrs[0] };
    }

    // Convert to valid date
    var expDT = new Date(dt);
    if (isNaN(expDT.getTime())) {
        // If invalid date string, default to Status 0
        return { Status: 0, bclr: bclrs[0], fclr: fclrs[0] };
    }

    var thisDT = new Date();
    var DTPlus60 = new Date();
    DTPlus60.setDate(thisDT.getDate() + 60);

    // Determine status
    if (expDT > DTPlus60) {
        status = 1; // valid, far from expiry
    } else if (expDT > thisDT) {
        status = 2; // within 60 days
    } else {
        status = 3; // expired
    }

    return { Status: status, bclr: bclrs[status], fclr: fclrs[status] };
}



function FileHover(e, overOut, fid, fdrid) {
    var x = e.clientX + 5, y = e.clientY + 15;
    //y = (document.body.scrollHeight - y < 10) ? y - 50 : y;

    var goY = "top:" + y + "px";
    if (document.body.scrollHeight - y < 100) { goY = "bottom:60px"; }

    
    if (overOut == 0) {
        var FD = FileDetails(fid, fdrid);
        console.log(fid, FD);

        var fh = document.getElementsByClassName("FileHover");
        try {
            for (var i = 0; i < fh.length; i++) {
                fh[i].parentElement.removeChild(fh[i]);
            }
        } catch (ex) { }

        if (FD.length > 0) {
            xsection(PageContainer, ["div|id=divFileHover_" + fid +
                "|onmouseout=PageContainer.removeChild(divFileHover_" + fid + ")|class=sm FileHover|style=" + goY + "; left:" + x + "px"]);
            nsection("divFileHover_" + fid, FD);
        }
    } else {
        try {
            var nt = document.getElementById("divFileHover_" + fid);
            PageContainer.removeChild(nt);
        } catch (e) {}
    }
}
function removeFileHovers() {
    var fh = document.getElementsByClassName("FileHover");
    for (var i = 0; i < fh.length; i++) { var x = fh[i]; x.parentElement.removeChild(x);}
}

function FileDetails(fid, fdrid) {
    var xx = jsOFiles.filter(d => d.FID == fid && d.FdrID == fdrid)[0];
    console.log(jsOFiles, xx);
    var Status = (xx.Status == "") ? "Current: Expires" : xx.Status;

    var js = [];
    try {
        js = [
            "table" +
            "|||append|tr|||append|td|Created By: |||td| " + xx.CreatedBy +
            "|||cancel|tr|||append|td|Date Created: |||td| " + convertDT(xx.DTCreated) +
            ((xx.DTModified == null) ? "" : "|||cancel|tr|||append|td|Modified By: |||td| " + xx.ModifiedBy) +
            ((xx.DTModified == null) ? "" : "|||cancel|tr|||append|td|Date Modified: |||td| " + convertDT(xx.DTModified)) +

            "|||cancel|tr|||append|td|Status: |||td|" + Status + ": " + ((xx.ExpDT == null) ? "Not set" : convertDT(xx.ExpDT, true)) + // + ((xx.ExpDT) ? " [" + xx.ExpDT + "]" : "") +

            //"div|NID: " + xx.NID, 
            ((xx.Note_Created == null) ? "" : "|||cancel|tr|||append|td|Last Note: |||td| " + xx.Last_Note) +
            ((xx.Note_Created == null) ? "" : "|||cancel|tr|||append|td|Note Created By: |||td| " + xx.Note_Created_By) +
            ((xx.Note_Created == null) ? "" : "|||cancel|tr|||append|td|Date Note Created: |||td| " + convertDT(xx.Note_Created)) +
            ((xx.Note_Created == null) ? "" : "|||cancel|tr|||append|td|Note Shared With: |||td| " + xx.Note_Shared_With) +
            ((xx.Parent != -1) ? "" :
                ((xx.LinkedToCMS == null) ?
                    "|||cancel|tr|||append|td|colspan=2|Exam File is not linked to CMS" :
                    "|||cancel|tr|||append|td|CMS Link: |||td| " + xx.LinkedToCMS
                )
            ) +
            ((xx.ReportID == null || xx.ReportID == "") ? "" : "|||cancel|tr|||append|td|Dynamic Report: |||td| " + xx.ReportName) +
            ((xx.ReportID == null || xx.ReportID == "") ? "" : "|||cancel|tr|||append|td|Attachments: |||td| " + xx.Attachments)
        ];
    } catch (e) {
        console.log(xx);
    }
    return js;
}
