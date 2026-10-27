//**************************************************************************************************
//******************************MGT Exams **********************************************************
//**************************************************************************************************
//log update 20260422-127p
// Management-side compliance exam viewer/editor: question navigation, per-line scoring/answers,
// CMS-file/document-request attachments, heatmap report generation, and exam/heatmap PDF+zip export.
var questionBG, questionNM;
var MGTScoringTypes = [];
var MGTPrimaryFields = ["ManagingCompany", "ExamID", "Name", "Module", "ModNum", "QuestNum", "Question"];
var MGTAuditButtons = [];
//code:jk-20240904:109pm - added jsMGTScores
var jsMgtExam = [], jsMgtReport = [], jsMgtAnswers = [], MGTAuditLayers = [], jsMgtDocs = [], jsMGTScores = [];
var jsMgtScoring = [];
var MgtExamID, MgtExamName, MgtXCID, MgtXCompany;
var pagebreak = "pagebreak|style=page-break-before:always";
var jsMgtHeatmapForm = {};
var mgtPdfDoc = "";
var jsRemediationsStore = [];
var jsHeatmapStaticPages = [];
var MGTLineIDs = [];
var jsExamCMSFiles = [], selectedCMSFiles = [], MGTUploadDocs_Params = [];
var tmpCMSFiles = [];
var isShowHideDocRequestsActive = false;//code:so 20240705 12:11pm;added the isShowHideDocRequestsActive variable to manage state
var curExamDocs = [];

let isDocumentActive = false;
let isRequestActive = false;
let isScoringActive = false;
let isLikelihoodActive = false;
let isControlActive = false;
let isRecommendedRemediationActive = false;
let isReferenceSourceActive = false;

//code:jk-20240904:109pm - added hasFocused for initial set focus
var hasFocused = false;

//code:20261027 the exam stays hidden behind "Please wait while the exam is loading ..." until the build and its
//async fills (answers, scores, last-view layers) have all finished. Each load gets an id so a slow callback from a
//previously selected exam can't reveal the current one; a 60s fallback reveals anyway if a call never comes back.
var mgtExamLoadID = 0;
function mgtExamLoadBegin(steps) {
    var id = ++mgtExamLoadID;
    ["ExamOpts", "availExamsInner"].forEach(function (d) {
        var el = document.getElementById(d);
        if (el) el.style.display = "none";
    });
    var done = function () {
        if (id != mgtExamLoadID || --steps > 0) return;
        mgtExamLoadID++;
        var msg = document.getElementById("examLoadingMsg");
        if (msg) msg.remove();
        ["ExamOpts", "availExamsInner"].forEach(function (d) {
            var el = document.getElementById(d);
            if (el) el.style.display = "";
        });
        FocusLastQuestion();    //needs the exam visible to focus/scroll
    };
    setTimeout(function () { steps = 1; done(); }, 60000);
    return done;
}

// ============================================================
// SECTION: numeric helper, document-request/scoring visibility toggles, CMS-file lookup, main exam
// viewer load (viewMgtExam is the big entry point building the whole exam UI)
// ============================================================
function between(num, x, y) {
    return (num >= x && num <= y);
}

function showHideDocRequests(ExamID, xcid) {//code:so 20240705 12:11pm; edited part of the showHideDocRequests() function
    var elem = document.getElementsByClassName("mgtDocSection");
    isShowHideDocRequestsActive ? true : false;
    var showHide = (elem[0].style.display == "none") ? "" : "none";

    // Update the state based on the current display style
    isShowHideDocRequestsActive = (showHide === "");
    isDocumentActive = (showHide === "");

    auditBtnDR.style.backgroundColor = (showHide == "") ? "yellow" : "white";
    for (var i = 0; i < elem.length; i++) {
        elem[i].style.display = showHide;
    }



    //if (isShowHideDocRequestsActive) {
    //    var exportPopupButton = document.getElementById("exportButton");
    //    exportPopupButton.innerHTML = "";
    //    exportPopupButton.className = "blueButton";
    //    exportPopupButton.onclick = function () { exportHTML2PDF('exportedDiv', 'CMSEXPORTESTRUN') };
    //    exportPopupButton.innerText = "Export Zip";
    //}
    //else {
    //    var exportPopupButton = document.getElementById("exportButton");
    //    exportPopupButton.innerHTML = "";
    //    exportPopupButton.className = "blueButton";
    //    exportPopupButton.onclick = function () { exportHTML2PDF('exportedDiv', 'CMSEXPORTESTRUN') };
    //    exportPopupButton.innerText = "Print PDF";
    //}


    //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
    getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "DocumentRequest", onOff: (showHide === "") }), function (vr) {
        var js = jparse(vr);
        ////c_log(js);
    });


}


function showHideScoring(ExamID, xcid) {
    ////c_log("Scoring",xcid);
    var elem = document.getElementsByName("auditHdrScoring");
    var delem = document.getElementsByName("auditHdrDefScoring");
    var showHide = (elem[0].style.display == "none") ? "" : "none";
    isScoringActive = (showHide === "");
    auditBtnSC.style.backgroundColor = (showHide == "") ? "yellow" : "white";
    for (var i = 0; i < elem.length; i++) {
        elem[i].style.display = showHide;
    }
    for (var i = 0; i < delem.length; i++) {
        delem[i].style.display = showHide;
    }
    //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
    getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "Scoring", onOff: (showHide === "") }), function (vr) {
        var js = jparse(vr);
        ////c_log(js);
    });
}



function MGTSetLayer(ix, ExamID, xcid) {
    ////c_log(ix, ExamID, xcid);
    //alert("here");
    try {
        var btn = document.getElementById("auditBtn_" + ix);
        var btnZero = document.getElementById("auditBtn_0");
        var btnOne = document.getElementById("auditBtn_1");
        var btnTwo = document.getElementById("auditBtn_2");
        var btnThree = document.getElementById("auditBtn_3");
        var abtn = MGTAuditButtons[ix];
        var dsp;
        ////c_log(MGTAuditButtons);
        ////c_log(MGTAuditLayers);

        //var elem = document.getElementsByName("auditHdr_" + ix);
        //var dsply = (elem[0].style.display == "none") ? "" : "none";
        //for (var i = 0; i < elem.length; i++) {
        //    elem[i].style.display = dsply;
        //}

        for (var i = abtn["Min"]; i < abtn["Max"]; i++) {
            var x = document.getElementsByName("auditHdr_" + i);
            var xx = document.getElementsByName("auditHdrTxt_" + i);
            var setfocus = false;

            for (var ii = 0; ii < x.length; ii++) {
                try {
                    if (xx[ii].innerHTML != "" || 1 == 1) {
                        dsp = (dsp != null) ? dsp : (x[ii].style.display == "none") ? "" : "none";
                        if (dsp == "" && !setfocus) {
                            setfocus = true;
                            x[ii].focus();
                        }
                        x[ii].style.display = dsp;
                    }
                } catch (ex) {
                    ////c_log(ex);
                }
            }
        }

        btn.style.backgroundColor = (dsp == "") ? "yellow" : "";
        if (btn == btnZero) {
            isLikelihoodActive = (dsp == "");
            //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
            getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "Likelihood", onOff: (dsp == "") }), function (vr) {
                var js = jparse(vr);
                ////c_log(js);
            });
        } else if (btn == btnOne) {
            isControlActive = (dsp == "");
            //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
            getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "Control", onOff: (dsp == "") }), function (vr) {
                var js = jparse(vr);
                ////c_log(js);
            });
        } else if (btn == btnTwo) {
            isRecommendedRemediationActive = (dsp == "");
            //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
            getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "RecommendedRemediation", onOff: (dsp == "") }), function (vr) {
                var js = jparse(vr);
                ////c_log(js);
            });
        } else {
            isReferenceSourceActive = (dsp == "");
            //code: 20240819: 0400pm Send Data to the _MGTUpdateLastView SP
            getData(null, newFormData("_MGTUpdateLastView", { examid: ExamID, xcid: xcid, button: "ReferenceSource", onOff: (dsp == "") }), function (vr) {
                var js = jparse(vr);
                ////c_log(js);
            });
        }

        dsp = "none";
        var btns = document.getElementsByName("auditBtn");
        for (var i = 0; i < btns.length; i++) {
            if (btns[i].style.backgroundColor == "yellow") { dsp = ""; }
        }
    } catch (ex) {
        ////c_log(ex);
    }

}

function ftnGetCMSFiles(xCID, func) {
    ////c_log("jsExamCMSFiles", xCID, jsExamCMSFiles);
    getData(null, newFormData("_MGTGetCMSFiles", { xcid: xCID }), function (vr) {
        var js = jparse(vr);

        ////c_log("jsExamCMSFiles", js);

        //try {
        //    //GET FOLDER MAP
        //    for (var i = 0; i < js.length; i++) {
        //        var xx = js[i];
        //        var fdrid = xx.FdrID;
        //        var folder = xx.Folder;
        //        var fdrs = [folder];


        //        var go = true, goix = 0;
        //        while (go && goix < 100) {
        //            goix++; //failsafe
        //            var ix = jsFolders.findIndex(d => d.FdrID == fdrid);
        //            fdrid = jsFolders[ix].Parent;
        //            var pix = jsFolders.findIndex(d => d.FdrID == fdrid);
        //            if (pix == -1) {
        //                go = false;
        //            } else {
        //                fdrs.push(jsFolders[pix].Folder);
        //            }
        //        }

        //        xx.Folder = fdrs.reverse().join(" / ");
        //    }
        //} catch (ex) {
        //    ////c_log("jsExamCMSFiles", "error", ex);
        //}
        //END FOLDER MAP
        jsExamCMSFiles = js;
        tmpCMSFiles = js;
        ////c_log("jsExamCMSFiles", jsExamCMSFiles, js, tmpCMSFiles);

        if (func != null) { func(); }
    });
}

function GetZipFile(ExamID, xCID) {
    //windowOpen("GetExamDocs?ExamID=" + ExamID + "&xCID=" + xCID);
    PopUp("Show Exam Zip Options", [ExamID, xCID], null, null, ["auto", "420px"]);

}
let isQuestionByQuestionMode = false;//2025 code: 16012025 3:00pm
let currentQuestionIndex = 0;//2025 code: 16012025 3:00pm
function viewMgtExam(ExamID, xcid, xcompany, snapshot) {
    //code:20261001 snapshot = row from _MgtGetExamSnapshots to view read-only; omitted = live exam
    setMgtSnapshot(snapshot);
    //    ////c_log(ExamID, xcid);
    //    getData(null, newFormData("_MGTGetLastView", { examid: ExamID, xcid: xcid } ), function (vr) {
    //        var js = jparse(vr);
    //        ////c_log(js);
    //        // Iterate through the array to find the object with Button = "DocumentRequest"
    //        var documentRequest = js.find(item => item.Button === "DocumentRequest");

    //        // Check if the object was found and if its OnOff property is true
    //        if (documentRequest && documentRequest.OnOff === true) {
    //            ////c_log(ExamID, xcid);
    //            showHideDocRequests(ExamID, xcid);

    //        }
    //});

    ftnGetCMSFiles(xcid);

    var examShare = (jsUserParts.findIndex(d => d.part == "Comp-ExaSha" || d.part == "Comp-A") == -1) ? false : true;
    c_log(xcid, xcompany, myCompany);
    xcompany = (xcid == 0) ? myCompany : xcompany;
    MgtExamID = ExamID;
    MgtXCID = xcid;
    MgtXCompany = xcompany;

    var main = document.getElementById("ContentWindow");
    main.innerHTML = "";

    main.appendChild(dyn("div", "class=shadowSection|id=ExamHeader"));
    main.appendChild(dyn("div", "id=ExamOpts"));


    if (!document.getElementById("nextPrevBtnsContainer"))
        xsection(ContentWindow, ["div|id=nextPrevBtnsContainer"]);
    var sub = document.getElementById("nextPrevBtnsContainer");
    sub.innerHTML = "";
    sub.appendChild(dyn("div", "id=QbyQprevNextBtns"));

    section("ExamHeader", [
        "a|style=color:steelblue|class=excludePrint|onclick=currentExam~null; buildAvailExams(" + xcid + ",'" + xcompany + "')|innerHTML=< --Back to Exams Selection", // ... " + templateid,
        "L|style=padding-left:20px;font-weight:bold|id=ExamName",
        //"label|style=float:right|class=blueButton excludePrint|onclick=printExam()|Print Exam"
    ]);
    if (MgtSnapshot) { buildSnapshotBanner(ExamID, xcid, xcompany); }

    c_log(myCID, xcid);
    section("ExamOpts", [
        //code:20261026 the right-hand exam options (Print to PDF, Heatmap Report, Exam Zip Options, Snapshots, Workflow)
        //live in one "Actions" dropdown; Question-by-Question View stays a toggle. See buildExamActions / addExamAction.
        "label|style=float:right|id=examActionsWrap|class=excludePrint",
        "label|style=float:right; width:10px|",
        //code:so 20240705 12:11pm; Added the print to PDF button
        //"label|style=float:right; color:maroon|class=alink excludePrint|onclick=PopUp('PDF Preview', null, null, true)|Print to PDF",
        "label|style=float:right|id=srchGrades",
        //"label|style=float:right; width:10px|",
        //"label|style=float:right; color:maroon|class=alink excludePrint|onclick=showOnlyAttachments()|Attachment View",
        //((xcid != 0) ? "label|style=float:right; color:maroon|class=alink excludePrint|onclick=generateJSReport()|Heatmap Report" : ""),
        "label|style=float:right|id=sectExamSharing|class=excludePrint",
        "label|style=float:right; width:10px|",
        "label|class=toggle-switch|style=float:right;|id=toggle_switch_id",
        "label|style=float:right; width:10px|",
        "label|id=toggleState|style=float:right;color:maroon|Question-by-Question View",
        "label|style=float:right; width:5px|",
       // "label|style=float:right;color:maroon|Zip Attachments",
      //  ((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "label|style=float:right;color:maroon;|onclick=GetZipFile('" + ExamID + "'," + xcid + ")|Zip Document Requests" : ""),
        "label|style=float:right; width:10px|",
        "label|style=float:right; width:5px|",
    ]);

    //function DownloadAttachments(mainid) {
    //    GetFile("GetIAZipFile", { mainid: mainid });
    //}
    section("toggle_switch_id", [
        // "input|type=checkbox|id=toggleSwitch|onchange=updateToggleState(this)",
        "input|type=checkbox|id=toggleSwitch|",
        "span|class=slider",

    ]);

    buildExamActions();
    addExamAction("Print to PDF", function () { PopUp('PDF Preview', null, null, true); });
    if (xcid != 0) { addExamAction("Heatmap Report", function () { generateJSReport(); }); }

    //section("srchGrades", ["label|class=alink excludePrint|style=color:maroon|onclick=searchGrades()|Needs Attention"]);

    var newHt = (document.body.scrollHeight - 320) + "px";
    var xx = divHt.filter(d => d.divName == "availExamsInner");
    if (xx.length > 0) { newHt = xx[0]["ht"]; }

    main.appendChild(dyn("div", "id=availExamsInner|style=width:100%;height:" + newHt + "; overflow-y:scroll"));
    main = document.getElementById("availExamsInner");
    if (MgtSnapshot) { main.classList.add("mgtSnapRO"); }

    //code:20261027 hide the exam until it is fully built: main build + answers + scores + last view
    main.parentNode.insertBefore(dyn("div", "id=examLoadingMsg|style=padding:20px; font-weight:normal; color:black|innerHTML=Please wait while the exam is loading ..."), main);
    var examLoaded = mgtExamLoadBegin(4);

    var btns = [
        "_MgtGetExam",
        "_MgtGetExamScoring",
        "_MgtGetHeatmapTypes",
        "_MgtGetExamDocs",
        "_MgtGetAuditButtons",
        "_MgtGetJSScoring",
        "_MgtGetForm",
        "_MgtGetHeatmapStaticPages"
    ];
    var prams = [
        { examid: ExamID, xcid: xcid },
        { examid: ExamID },
        { examid: ExamID },
        { examid: ExamID, xcid: xcid },
        { examid: ExamID },
        { examid: ExamID },
        { examid: ExamID, xcid: xcid },
        { examid: ExamID }
    ];
    console.log("323", btns, prams);
    var snapCalls = mgtSnapMap(btns, prams);

    RunMultiSP(snapCalls[0].join(","), snapCalls[1], function (js) {
        jsMgtExam = js[0];
        MGTScoringTypes = js[1];
        MGTAuditLayers = js[2];
        jsMgtDocs = js[3];
        MGTAuditButtons = js[4];
        jsMgtScoring = js[5];
        jsMgtHeatmapForm = js[6][0];
        jsHeatmapStaticPages = js[7];
        MGTLineIDs = [];

        c_log(jsMgtDocs);
        console.log("jsMgtExam[0]:", jsMgtExam[0]);
        hasFocused = false;

        var ExamOwnerCID = jsMgtExam[0].OwnerCID;

        MgtExamName = jsMgtExam[0]["Name"];

        section("ExamName", [
            ////code:so 20240705 12:11pm; Added ids (examVal and assignedToVal)
            "label|style=font-weight:normal; padding-left:20px; padding-right:5px|Exam: ",
            "label|style=font-weight:bold; padding-right:50px|id=examVal| " + jsMgtExam[0]["Name"],
            "label|style=font-weight:normal; padding-right:5px|Assigned to: ",
            "label|style=font-weight:bold; padding-right:50px|id=assignedToVal| " + xcompany,
            "label|style=font-weight:normal; padding-right:5px;display:none;|id=sectionLabel|for=examSectionDropdown|Section: ",//code 02032025 16:30
           // "label|style=font-weight:bold; padding-right:50px;display:none;|id=examSectionHeader| ",//code 02032025 16:30
            "select|id=examSectionDropdown|class=excludePrint|style=padding:5px; font-weight:bold; color:steelblue;|onchange=navigateToModule(this.value)",

            //          ((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "button|class=longblueButton|style=float:right|onclick=GetZipFile('" + ExamID + "'," + xcid + ")|Zip Document Requests" : "")
         //   ((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "a|icon=zip.png|icon.style=padding-right:5px;|class=excludePrint|style=float:right;color:steelblue|onclick=GetZipFile('" + ExamID + "'," + xcid + ")|Zip Document Requests" : ""),
        ])
        
        //code:20261026 Exam Zip Options and Snapshots moved into the Actions dropdown (same conditions as before)
        if (jsMgtDocs.filter(d => d.FID != null).length > 0) { addExamAction("Exam Zip Options", function () { GetZipFile(ExamID, xcid); }); }
        //code:20261001 exam snapshots (same visibility as the audit buttons)
        if ([ExamOwnerCID, xcid].indexOf(myCID) > -1) { addExamAction("Snapshots", function () { showExamSnapshots(ExamID, xcid); }); }
        section("ExamOpts", [
            //((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "label|class=alink excludePrint|style=float:right;color:maroon;|onclick=GetZipFile('" + ExamID + "'," + xcid + ")|Exam Zip Options" : ""),
            //(([ExamOwnerCID, xcid].indexOf(myCID) > -1) ? "label|class=alink excludePrint|style=float:right;color:maroon;padding-right:20px|onclick=showExamSnapshots('" + ExamID + "'," + xcid + ")|Snapshots" : ""),
            //((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "label|class=alink excludePrint|style=float:right;color:maroon;|onclick=createExamZipFile('" + ExamID + "'," + xcid + ")|Create Zip File" : ""),
            //((jsMgtDocs.filter(d => d.FID != null).length > 0) ? "label|class=alink excludePrint|style=float:right;color:maroon;|onclick=PopUp('Show Exam Zip Options', [xCID, ExamID, LineID, DocReqID, fromPCorCMS], null, null, ["400px", "900px"])|Exam zip options" : ""),
            // PopUp("Exam Zip Options", [xCID, ExamID, LineID, DocReqID, fromPCorCMS], null, null, ["400px", "900px"]);
            //createExamZipFile('" + ExamID + "'," + xCID + ")|Create Zip File
            //PopUp("Show Exam Zip Options", [xCID, ExamID, LineID, DocReqID, fromPCorCMS], null, null, ["400px", "900px"]);
        ])
        //code:20261025 exam workflow link (added only if the server says this exam has one and the caller may see it)
        if (!MgtSnapshot) { loadWorkflowLink(ExamID, xcid); }

        //BUILD BANNER AND TABLE
        nsection("availExamsInner", [
            "div|id=topBanner",
            //"hr",
            "table|id=tblMain|style=width:100%"
        ]);

        try {
            nsection("ExamOpts", [
                "button|class=longblueButton|id=auditBtnDR|onclick=showHideDocRequests('" + ExamID + "', " + xcid + ")|Document Request", "label|&nbsp;&nbsp;",
                (byFolderCompany == 1 && ((isDownstream(xcid) || (myCID == ExamOwnerCID && xcid != 0))) ? "button|class=longblueButton|id=auditBtnSC|onclick=showHideScoring('" + ExamID + "', " + xcid + ")|Scoring" : ""),
                (byFolderCompany == 1 && ((isDownstream(xcid) || (myCID == ExamOwnerCID && xcid != 0))) ? "label|&nbsp;&nbsp;" : "")
            ]);
        } catch (ex) {
            //c_log(ex);
            alert("err");
        }

        if (byFolderCompany == 1 && (isDownstream(xcid) || (myCID == ExamOwnerCID && xcid != 0))) {
            for (var i = 0; i < MGTAuditButtons.length; i++) {
                nsection("ExamOpts", [
                    "button|class=longblueButton|name=auditBtn|id=auditBtn_" + i + "|onclick=MGTSetLayer(" + i + ",'" + ExamID + "', " + xcid + ")|" + MGTAuditButtons[i]["Title"].replace(/_/g, " "), "label|&nbsp;&nbsp;"
                ]);
            }
        }

        //BUILD HEADER
        nsection("tblMain", ["tr|id=trHeader"]);

        //BUILD BODY
        var Assessment_Module = "";
        var bgclr = "";

        var displayHeaders = [];
        var uniqueModules = [];
        //EXAM LOOP
        console.log("err", jsMgtExam);
        for (var i = 0; i < jsMgtExam.length; i++) {
            displayHeaders = [];

            var LineID = jsMgtExam[i]["LineID"];
            var strLineID = LineID.replace(/-/g, "");
            var hasHeatmap = (jsMgtExam[i].Heatmap_Statement != "") ? true : false;

            MGTLineIDs.push({ ExamID: ExamID, LineID: LineID, strLineID: strLineID, xCID: MgtXCID });

            //SHOW SECTION
            bgclr = (bgclr == "whitesmoke" ? "white" : "whitesmoke");
            if (Assessment_Module != jsMgtExam[i]["Module"]) {
                Assessment_Module = jsMgtExam[i]["Module"];
                Assessment_Module = (Assessment_Module == null) ? "" : Assessment_Module;

                var actual_Assessment_Module;
                for (var am = 0; am < i + 1; am++) {
                    if (jsMgtExam[am]["Module"] != null && jsMgtExam[am]["Module"] != "")
                        actual_Assessment_Module = jsMgtExam[am]["Module"]
                }
                nsection("tblMain", ["tr|tabindex=0|id=trSection_" + strLineID + "|||td|style=font-weight:bold|" + actual_Assessment_Module]);
                bgclr = "whitesmoke";

                // Track unique modules along with their row target ID for navigation
                if (actual_Assessment_Module && uniqueModules.findIndex(m => m.name === actual_Assessment_Module) === -1) {
                    uniqueModules.push({ name: actual_Assessment_Module, targetId: "trSection_" + strLineID });
                }
            }

            //section dropdown options are written once after the loop (was cleared and rebuilt for every question)

            nsection("tblMain", ["tr|id=question-" + i + "|onmouseover=showQuestionModuleLabel('" + actual_Assessment_Module + "'); // Corrected: Use arrow function|tabindex=0|class=question question_" + strLineID + "|||" + //code 02032025 16:30
                "td|style=padding-left:30px;background-color:" + bgclr + "|" + jsMgtExam[i]["QuestNum"] + " " + jsMgtExam[i]["Question"].replace(/=/g, "~"),

            ]);

            //Answer
            nsection("tblMain", ["tr" + "|||" +
                // "td|id=tdAnswer_" + strLineID + "|style=background-color:" + bgclr + "; padding:5px; padding-left:30px;|onmouseenter=debouncedQuestionBG(" + i + ")|onmouseleave=debouncedQuestionNM(" + i + ")"//2024 code: 20240821 4:00pm
                "td|id=tdAnswer_" + strLineID + "|onmouseover=showQuestionModuleLabel('" + actual_Assessment_Module + "')|style=background-color:" + bgclr + "; padding:5px; padding-left:30px;|"//2025 code: 16012025 3:00pm

            ]);

            //nsection("tdAnswer_" + strLineID, [
            //    "div|style=display:none;|class=navigation-buttons|id=navigationBtns" + i
            //]);

            nsection("QbyQprevNextBtns", [//code:20012025 1:00pm
                //nextPrevContainer
                "div|style=display:none;|class=navigation-buttons|id=navigationBtns" + i
            ]);

            nsection("navigationBtns" + i, [
                "button|onclick=previousQuestion(" + i + ")|<< Prev",
                "button|onclick=nextQuestion(" + i + ")|Next >>",
            ]);

            //Answer Types
            nsection("tdAnswer_" + strLineID, [
                "textarea|style=width:100%|class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "',0)|id=answer_" + strLineID + "_0",
                "div|style=padding-left:10px; padding:5px|class=answerDetails|id=answerDetails_" + strLineID + "_0",
                "div|style=padding-left:30px; padding:5px;display:none|class=mgtDocSection|id=answerDocs_" + strLineID,
                "div|id=tdOtherAnswer_" + strLineID + "|style=background-color:" + bgclr + "; padding:5px; padding-left:30px;",//code: 07222024 5:00pm Add the "tdOtherAnswer_" Div.
            ]);


            //append audit sections to the exam answers
            //Likelihood, Magnitude, Control Section
            //  nsection("tdAnswer_" + strLineID, ["table|id=tblAuditScoring_" + strLineID + "|style=width:70%;|||tr|id=G" + strLineID]);//code: 20240820: 0432pm Change width of table to 70%
            nsection("tdAnswer_" + strLineID, [
                "table|id=tblAuditScoring_" + strLineID + "|style=width:70%;",

            ]);
            nsection("tblAuditScoring_" + strLineID, [
                "tr|id=trAuditScoring_" + strLineID,
                // "tr|name=smallWidth|style=display:none;|id=trAuditScoringMini_" + strLineID,
            ])

            var fldLen = (MGTScoringTypes.length > 0) ? MGTScoringTypes[0]["FldLength"] : 0;

            //SCORING LOOP INSIDE MAIN EXAM LOOP
            for (var f = 0; f < fldLen; f++) {
                var ix = (f + 1);
                //  //c_log(window.innerWidth);

                nsection("trAuditScoring_" + strLineID, [
                    "td|class=bigTD|||div|name=" + ((!hasHeatmap) ? "xxx" : "") +
                    "auditHdrScoring|style= padding:1%; font-weight:bold; display:none|" + MGTScoringTypes[0]["Fld" + ix] +//code: 20240820: 0432pm Change Units from px to %
                    "|||div|id=auditHdrScoring_Fld" + ix + "_" + strLineID +
                    "|name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrScoring|style=padding-left:3%; display:none"//code: 20240820: 0432pm Change Units from px to %
                ]);

                var FldVals = MGTScoringTypes[0]["Fld" + ix + "Vals"].split(",");
                var FldDsps = MGTScoringTypes[0]["Fld" + ix + "Dsp"].split(",");
                FldDsps = (FldDsps == null) ? FldVals : FldDsps;

                for (var ff = 0; ff < FldVals.length; ff++) {
                    var FldVal = FldVals[ff];
                    var FldDsp = FldDsps[ff];

                    nsection("auditHdrScoring_Fld" + ix + "_" + strLineID, [
                        "append|input|type=radio|class=ocInput|onchange=CalcNetScores('" + LineID + "'," + ix + ")|class=auditScoring|name=auditScoring_Fld" + ix + "_" + strLineID +
                        "|value=" + FldVal + "|id=auditScoring_Fld" + ix + "_" + FldVal + "_" + strLineID,
                        "label|for=auditScoring_Fld" + ix + "_" + FldVal + "_" + strLineID + "|style=padding-left:-1%; padding-right:5%|" + FldDsp//code: 20240820: 0432pm Change Units from px to %
                    ]);


                }
            }



            //APPLY NET SCORE
            nsection("trAuditScoring_" + strLineID, [
                "td|||div|id=auditHdrScoring_Net_0_" + strLineID + "|name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrScoring|style=padding-left:3%; font-weight:bold; display:none|Net Score" + //code: 20240820: 0432pm Change Units from px to %
                "|||div|id=auditHdrScoring_Net_1_" + strLineID + "|name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrScoring|style=display:none;padding:5%|N/A"//code: 20240912: 105pm
            ]);
            nsection("trAuditScoring_" + strLineID, [
                "label|onclick=mgtResetScoringLine('" + strLineID + "','" + LineID + "')|" +
                "name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrScoring|id=resetScoring_" + strLineID + "|class=cursor resetScoring|style=padding-left:3%; float:right; cursor:pointer; color:red; display:none",
                //"label|style=width:10px|",

                "label|onclick=MGTSetDefaultScores(false, '" + LineID + "')|" +
                "name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrDefScoring|id=defaultScoring_" + strLineID + "|class=cursor resetScoring|style=padding-left:3%; float:right; cursor:pointer; color:green; display:none",

                //"label|id=defaultScoring_" + strLineID + "|onclick=MGTSetDefaultScores(false, '" + LineID + "')|class=cursor sm resetScoring|style=display:none;padding-left:3%; float:right; cursor:pointer; color:green" 
            ]);
            nsection("tdAnswer_" + strLineID, [
                "hr|name=" + ((!hasHeatmap) ? "xxx" : "") + "auditHdrScoring|style=display:none"
            ]);


            //c_log(MGTAuditLayers);
            let likelihoodHDR = false;//code: 07112024:3:08pm
            let recommendedRemediationHDR = false;//code: 07112024:3:08pm
            let controlHDR = false;//code: 07112024:3:08pm
            let refferenceHDR = false;//code: 07112024:3:08pm


            //MGT SECTIONS LOOP INSIDE MAIN LOOP
            if (byFolderCompany == 1) {
                for (var ix = 0; ix < MGTAuditLayers.length; ix++) {
                    var isRemediation = MGTAuditLayers[ix]["Remediation"];


                    var alix = MGTAuditLayers[ix]["ix"],
                        alType = MGTAuditLayers[ix]["Type"],
                        alOptions = MGTAuditLayers[ix]["Options"],
                        alName = MGTAuditLayers[ix]["Name"],
                        alRemediation = MGTAuditLayers[ix]["Remediation"];


                    //alName = alName + '____'
                    //var arrAlName = alName.split("_");
                    //arrAlName.length = 3;
                    //alName = arrAlName.join("_");
                    //c_log("541x", arrAlName, alName);

                    let replacedString = alName.replace(/_/g, " ");//code: 07112024:3:08pm
                    let frstHdrsArray = replacedString.trim().split(/\s+/);//code: 07112024:3:08pm
                    let wordsArray = replacedString.trim().split(/\s+/); // Split by one or more spaces//code: 07112024:3:08pm
                    frstHdrsArray.pop();//code: 07112024:3:08pm
                    let frstHeader = frstHdrsArray.join(" ");//code: 07112024:3:08pm
                    wordsArray.shift(); // Remove the first word//code: 07112024:3:08pm
                    let resultFrstString = wordsArray.join(" ");//code: 07112024:3:08pm

                    frstHeader = (frstHeader == "Recommended") ? "Recommended Remediation" : frstHeader;
                    frstHeader = (frstHeader == "Reference") ? "Reference Source" : frstHeader;

                    var displayHeader = frstHeader;
                    if (displayHeaders.indexOf(frstHeader) == -1)
                        displayHeaders.push(frstHeader);
                    else
                        displayHeader = "";



                    //c_log(frstHdrsArray);
                    if (jsMgtExam[i][alName] == null || jsMgtExam[i][alName] == "") {
                        //c_log("here here here");
                    } else {
                        ////c_log(alName, jsMgtExam[i], jsMgtExam[i][alName]);

                        var qDisplay = (["no display", ""].indexOf(jsMgtExam[i][alName]) > -1) ? "none" : "";
                        var name = alName;
                        var val = jsMgtExam[i][name];

                        //c_log(541, frstHeader, alType);

                        c_log(541, ix, MGTAuditLayers, alName, jsMgtExam[i]);

                        if (val != "") {
                            nsection("tdOtherAnswer_" + strLineID, [//code: 07222024 5:00pm Change to tdOtherAnswer_
                                "div|name=auditHdr_" + ix + "|style=display:none|||" +
                                "div|tabindex=0|style=padding-left:30px|id=auditBody_" + strLineID + "_" + ix
                            ]);
                            if (displayHeader != "")
                                nsection("auditBody_" + strLineID + "_" + ix, ["p|style=font-weight:bold;|" + displayHeader + "s"])
                        }
                        if (alType != "checkbox") {
                            c_log(val);
                            if (val != "") {
                                //if (displayHeader != "")
                                //    nsection("auditBody_" + strLineID + "_" + ix, ["p|style=font-weight:bold;|" + displayHeader + "s"])

                                //nsection("tdAnswer_" + strLineID, [  //code: 07222024 5:00pm change to tdOtherAnswer_
                                //nsection("tdOtherAnswer_" + strLineID, [//code: 07222024 5:00pm change to tdOtherAnswer_
                                //    "div|name=auditHdr_" + ix + "|style=display:none|||" +
                                //    "div|tabindex=0|style=padding-left:30px|id=auditBody_" + strLineID + "_" + ix
                                //]);
                                //if (frstHeader == "Likelihood Question") {


                                try {
                                    var thisFldID = "answer_" + strLineID + "_" + (ix + 1);
                                    nsection("auditBody_" + strLineID + "_" + ix, [
                                        // "li|class=" + frstHeader + "|<b>" + alName.replace(/_/g, " ") + "</b>",
                                        //"div|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                        //"p|" + ((!likelihoodHDR) ? "style=font-weight:bold;|" + frstHeader + "s - sizingtext" : "style=display:none;"),//code: 07112024:3:08pm
                                        "li|class=" + frstHeader + "|style=xdisplay:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                        ((isRemediation) ?
                                            "|||input|type=checkbox|style=display:none|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ",'CB', true)|value=x" +
                                            name + "|class=ocInput xremediations_" + strLineID + "|id=cb_" + thisFldID + "|||label|style=padding-left:5px|" :
                                            "|"
                                        ) +
                                        jsMgtExam[i][alName].replace(/_/g, " ").replace(/=/g, "~"),
                                        "textarea|style=width:100%|class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ")|id=" + thisFldID,
                                        "div|style=padding-left:10px; padding:5px|class=answerDetails|id=answerDetails_" + strLineID + "_" + (ix + 1) + "|"
                                    ]);
                                } catch (ex) {
                                    console.log("invalid char", ex, {
                                        strLineID: strLineID, ix: ix, frstHeader: frstHeader, qDisplay: qDisplay, isRemediation: isRemediation, LineID: LineID,
                                        name: name, thisFldID: thisFldID, alname: jsMgtExam[i][alName].replace(/_/g, " ")
                                    });
                                }
                                //likelihoodHDR = true;//code: 07112024:3:08pm
                                ///////////////////////////Recommended
                                //} else if (frstHeader.indexOf("Recommended") == 0) {
                                //    var thisFldID = "answer_" + strLineID + "_" + (ix + 1);
                                //    nsection("auditBody_" + strLineID + "_" + ix, [
                                //        // "li|class=" + frstHeader + "|<b>" + alName.replace(/_/g, " ") + "</b>",
                                //        //"div|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        "p|" + ((!recommendedRemediationHDR) ? "style=font-weight:bold;|" + frstHeader + "s - sizingtext" : "style=display:none;"),//code: 07112024:3:08pm
                                //        "li|class=" + frstHeader + "|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        ((isRemediation) ?
                                //            "|||input|type=checkbox|style=display:none|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ",'CB', true)|value=x" +
                                //            name + "|class=ocInput xremediations_" + strLineID + "|id=cb_" + thisFldID + "|||label|style=padding-left:5px|" :
                                //            "|"
                                //        ) +
                                //        jsMgtExam[i][alName].replace(/_/g, " "),
                                //        "textarea|style=width:100%|class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ")|id=" + thisFldID,
                                //        "div|style=padding-left:10px; padding:5px|class=answerDetails|id=answerDetails_" + strLineID + "_" + (ix + 1) + "|"
                                //    ]);
                                //    recommendedRemediationHDR = true;//code: 07112024:3:08pm


                                //} else if (frstHeader == "Control Question") {
                                //    var thisFldID = "answer_" + strLineID + "_" + (ix + 1);
                                //    nsection("auditBody_" + strLineID + "_" + ix, [
                                //        // "li|<b>" + alName.replace(/_/g, " ") + "</b>",
                                //        //"div|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        "p|" + ((!controlHDR) ? "style=font-weight:bold;|" + frstHeader + "s - sizingtext" : "style=display:none;"),//code: 07112024:3:08pm
                                //        "li|class=" + frstHeader + "|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        ((isRemediation) ?
                                //            "|||input|type=checkbox|style=display:none|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ",'CB', true)|value=x" +
                                //            name + "|class=ocInput xremediations_" + strLineID + "|id=cb_" + thisFldID + "|||label|style=padding-left:5px|" :
                                //            "|"
                                //        ) +
                                //        jsMgtExam[i][alName].replace(/_/g, " "),
                                //        "textarea|style=width:100%|class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ")|id=" + thisFldID,
                                //        "div|style=padding-left:10px; padding:5px|class=answerDetails|id=answerDetails_" + strLineID + "_" + (ix + 1) + "|"
                                //    ]);
                                //    controlHDR = true;//code: 07112024:3:08pm
                                //} else if (frstHeader == "Reference") {
                                //    var thisFldID = "answer_" + strLineID + "_" + (ix + 1);
                                //    nsection("auditBody_" + strLineID + "_" + ix, [
                                //        // "li|<b>" + alName.replace(/_/g, " ") + "</b>",
                                //        //"div|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        "p|" + ((!refferenceHDR) ? "style=font-weight:bold;|" + frstHeader + "s - sizingtext" : "style=display:none;"),//code: 07112024:3:08pm
                                //        "li|class=" + frstHeader + "|style=display:" + qDisplay + "|name=auditHdrTxt_" + ix + "|style=padding:5px" +
                                //        ((isRemediation) ?
                                //            "|||input|type=checkbox|style=display:none|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ",'CB', true)|value=x" +
                                //            name + "|class=ocInput xremediations_" + strLineID + "|id=cb_" + thisFldID + "|||label|style=padding-left:5px|" :
                                //            "|"
                                //        ) +
                                //        jsMgtExam[i][alName].replace(/_/g, " "),
                                //        "textarea|style=width:100%|class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ")|id=" + thisFldID,
                                //        "div|style=padding-left:10px; padding:5px|class=answerDetails|id=answerDetails_" + strLineID + "_" + (ix + 1) + "|"
                                //    ]);
                                //    refferenceHDR = true;//code: 07112024:3:08pm
                                //}
                            }
                        } else if (alType == "checkbox") {// } && jsMgtExam[i][alName] != "") {
                            var name = alName;
                            var val = jsMgtExam[i][name];
                            //if (i == 0) { ix, val, c_log(MGTAuditLayers[ix], jsMgtExam[i]); }
                            //c_log(val, jsMgtExam[i]);


                            if (val != "") {
                                //c_log("HERE HERE HERE HERE HERE HERE HERE HERE HERE HERE HERE HERE ");
                                //nsection("tdAnswer_" + strLineID, [//code: 07222024 5:00pm Change to tdOtherAnswer_
                                //nsection("tdOtherAnswer_" + strLineID, [//code: 07222024 5:00pm Change to tdOtherAnswer_
                                //    "div|name=auditHdr_" + ix + "|style=display:none|||" +
                                //    "div|tabindex=0|style=padding-left:30px|id=auditBody_" + strLineID + "_" + ix
                                //]);

                                var repAlName = jsMgtExam[i][alName].replace(/=/g, "~").replace(/\|/g, "/");

                                nsection("auditBody_" + strLineID + "_" + ix, [
                                    // "li|<b>" + name.replace(/_/g, " ") + "</b>",
                                    //"p|id=recommended_HDR|" + ((!recommendedRemediationHDR) ? "style=font-weight:bold;|" + frstHeader + "s - checkbox" : "style=display:none;"), //code: 07112024:3:08pm
                                    //  "li|id=recommended_li|style=display:none",
                                    "input|type=checkbox|class=segment|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ",'CB')|value=x" +
                                    name + "|class=ocInput remediations_" + strLineID + "|id=answer_" + strLineID + "_" + (ix + 1),
                                    "input|type=hidden|value=" + name + "|id=cbanswer_" + strLineID + "_" + (ix + 1),
                                    ((repAlName.toLowerCase() != "other") ?
                                        "input|type=hidden|value=" + repAlName + "|id=txtanswer_" + strLineID + "_" + (ix + 1) :
                                        ""
                                    ),
                                    "label|class=recommended_li|style=display:" + ((repAlName.toLowerCase() == "other") ? "none" : "") + "; padding:5px; padding-left:10px|name=auditHdrTxt_" + ix + "|" + repAlName.replace(/_/g, " "),
                                    ((repAlName.toLowerCase() == "other") ?
                                        "textarea|style=width:95%|" + //id=txtanswer_" + strLineID + "_" + (ix + 1) :
                                        "class=ocInput|onchange=MGTAnswerOnchange('" + LineID + "'," + (ix + 1) + ")|id=" + thisFldID :
                                        ""
                                    ),
                                    "div|style=padding-left:10px; padding:5px|id=answerDetails_" + strLineID + "_" + (ix + 1)
                                ]);
                                //"textarea|style=width:95%|id=txtanswer_" + strLineID + "_" + (ix + 1)
                                //recommendedRemediationHDR = true;//code: 07112024:3:08pm
                            }
                        }
                    }
                }
            }
        }
        // Populate the dropdown options
        var dropdown = document.getElementById("examSectionDropdown");
        if (dropdown && uniqueModules.length > 0) {
            // 1. Clear out any previously appended options first
            dropdown.innerHTML = "";

            uniqueModules.forEach(function (mod) {
                xsection(examSectionDropdown, [
                    "option|value=" + mod.targetId + "|" + mod.name,
                ]);
            });
        }

        //c_log(ExamID, xcid);
        //code: 20240819: 0400pm Fetch data from the _MGTGetLastView SP
        getData(null, newFormData("_MGTGetLastView", { examid: ExamID, xcid: xcid }), function (vr) {
            var js = jparse(vr);
            //c_log(js);
            // Iterate through the array to find the object with Button = "DocumentRequest"
            var documentRequest = js.find(item => item.Button === "DocumentRequest");
            var control = js.find(item => item.Button === "Control");
            var likelihood = js.find(item => item.Button === "Likelihood");
            var recommendedRemediation = js.find(item => item.Button === "RecommendedRemediation");
            var referenceSource = js.find(item => item.Button === "ReferenceSource");
            var scoring = js.find(item => item.Button === "Scoring");

            // Check if the object was found and if its OnOff property is true
            if (documentRequest && documentRequest.OnOff === true) { showHideDocRequests(ExamID, xcid); }
            if (scoring && scoring.OnOff === true) { showHideScoring(ExamID, xcid) };
            if (likelihood && likelihood.OnOff === true) { MGTSetLayer(0, ExamID, xcid); };
            if (control && control.OnOff === true) { MGTSetLayer(1, ExamID, xcid) };
            if (recommendedRemediation && recommendedRemediation.OnOff === true) { MGTSetLayer(2, ExamID, xcid) };
            if (referenceSource && referenceSource.OnOff === true) { MGTSetLayer(3, ExamID, xcid) };

            examLoaded();
        });

        MGTPopAnswers(null, null, examLoaded);
        MGTPopDocs();
        MGTPopScores(examLoaded);

        examLoaded();
    });
    //2025 code: 16012025 3:00pm
    setTimeout(() => {
        const toggleSwitch = document.getElementById('toggleSwitch');
        if (toggleSwitch) {
            toggleSwitch.addEventListener('change', handleToggleChange);
        }
    }, 100);

}



// ============================================================
// SECTION: question navigation (module jump, prev/next, show-all, index-based display)
// ============================================================
function navigateToModule(targetId) {
    if (!targetId) return;

    var element = document.getElementById(targetId);
    var container = document.getElementById("availExamsInner"); // Your scrollable container

    if (element && container) {
        // 1. Get the vertical position of the element relative to the scrollable container
        var elementTop = element.offsetTop;
        container.scrollTo({
            top: elementTop,
            behavior: 'smooth'
        });

        element.focus();
    }
}

let questionTitleSectionState = false;//code 02032025 16:30

//2025 code: 16012025 3:00pm
function handleToggleChange(event) {

    isQuestionByQuestionMode = event.target.checked;
    const mainContent = document.getElementById('availExamsInner');

    if (isQuestionByQuestionMode) {
        availExamsInner.style.height = ((availExamsInner.style.height.replace("px", "") * 1) - 100) + "px";
        mainContent.classList.add('question-by-question-mode');
        showQuestionAtIndex(currentQuestionIndex);
        questionTitleSectionState = true;//code 02032025 16:30

    } else {
        availExamsInner.style.height = ((availExamsInner.style.height.replace("px", "") * 1) + 100) + "px";
        mainContent.classList.remove('question-by-question-mode');
        showAllQuestions();
        questionTitleSectionState = false;//code 02032025 16:30
        // Reset any floating modals
        if (typeof currentStickyQID !== "undefined" && currentStickyQID !== null) { // declaration is commented out with the old sticky-question code (~line 1203); without this guard, leaving Question-by-Question view threw
            questionNM(currentStickyQID);
        }
    }
    showPreviewQuestions();//code: 01242025 1:00pm
}
function showQuestionModuleLabel(Assessment_Module) {//code 02032025 16:30
    //alert(Assessment_Module);
    let examSectionHeader = document.getElementById("examSectionHeader");
    if (questionTitleSectionState || 1 == 1) {
        //document.getElementById("examSectionHeader").textContent = "";
        document.getElementById("sectionLabel").style.display = "";
        //document.getElementById("examSectionHeader").style.display = "";
        //document.getElementById("examSectionHeader").textContent = Assessment_Module;

        var dropdown = document.getElementById("examSectionDropdown");
        if (!dropdown) return;

        for (var i = 0; i < dropdown.options.length; i++) {
            if (dropdown.options[i].text === Assessment_Module) {
                dropdown.selectedIndex = i;
                break;
            }
        }
    } else {
        document.getElementById("sectionLabel").style.display = "none";
        //document.getElementById("examSectionHeader").style.display = "none";
        //document.getElementById("examSectionHeader").textContent = "";

        if (examSectionHeader) {
            examSectionHeader.style.display = "none";
            examSectionHeader.textContent = "";
        }
    }


}
//2025 code: 16012025 3:00pm
function showQuestionAtIndex(index) {
    if (!isQuestionByQuestionMode) return;

    const cursorQuestions = document.querySelectorAll('.question');//code: 01242025 1:00pm
    const questions = document.querySelectorAll('[id^=tdQuestion_]');//code: 01242025 1:00pm
    const answers = document.querySelectorAll('[id^=tdAnswer_]');
    const otherAnswers = document.querySelectorAll('[id^=tdOtherAnswer_]');
    let examSectionHeader = document.getElementById("examSectionHeader");
    document.getElementById("sectionLabel").style.display = "none";//code 02032025 16:30
    //document.getElementById("examSectionHeader").style.display = "none";//code 02032025 16:30
    //document.getElementById("examSectionHeader").textContent = "";//code 02032025 16:30

    questions.forEach((q, i) => {
        q.style.display = i === index ? '' : 'none';
        if (i === index) {
            q.classList.add('current-question');
        } else {
            q.classList.remove('current-question');
        }
    });

    // Add click event to cursorQuestions
    cursorQuestions.forEach((q, i) => {
        q.style.cursor = "pointer";
        q.onclick = () => showQuestionAtIndex(i); // Corrected: Use arrow function

    });


    answers.forEach((a, i) => {
        a.style.display = i === index ? '' : 'none';
    });

    otherAnswers.forEach((a, i) => {
        a.style.display = i === index ? '' : 'none';
        a.style.minHeight = i === index ? '500px' : '';//code:20012025 1:00pm
    });

    // Show navigation for current question
    const navBtns = document.getElementById('navigationBtns' + index);
    if (navBtns) {
        document.querySelectorAll('[id^=navigationBtns]').forEach(nav => {
            nav.style.display = 'none';
        });
        navBtns.style.display = 'flex';
    }

    // Scroll to question smoothly
    const currentQuestion = document.getElementById('question-' + index);
    if (currentQuestion) {
        //currentQuestion.scrollIntoView({ behavior: 'smooth', block: 'start' });
        availExamsInner.scrollTop = currentQuestion.offsetTop;
    }
    let Assessment_Module;//code 02032025 16:30
    if (Assessment_Module != jsMgtExam[index]["Module"]) {
        Assessment_Module = jsMgtExam[index]["Module"];
        Assessment_Module = (Assessment_Module == null) ? "" : Assessment_Module;
        document.getElementById("sectionLabel").style.display = "";//code 02032025 16:30
        //document.getElementById("examSectionHeader").style.display = "";//code 02032025 16:30
        //document.getElementById("examSectionHeader").textContent = Assessment_Module;//code 02032025 16:30

        var dropdown = document.getElementById("examSectionDropdown");
        if (!dropdown) return;

        for (var i = 0; i < dropdown.options.length; i++) {
            if (dropdown.options[i].text === Assessment_Module) {
                dropdown.selectedIndex = i;
                break;
            }
        }
    }



    // showPreviewQuestions();
}
//2025 code: 16012025 3:00pm
function showAllQuestions() {
    let examSectionHeader = document.getElementById("examSectionHeader");
    document.getElementById("sectionLabel").style.display = "none";
    //document.getElementById("examSectionHeader").style.display = "none";
    //document.getElementById("examSectionHeader").textContent = "";
    // const questions = document.querySelectorAll('.question');//code: 01242025 1:00pm
    const questions = document.querySelectorAll('[id^=tdQuestion_]');
    const answers = document.querySelectorAll('[id^=tdAnswer_]');
    const otherAnswers = document.querySelectorAll('[id^=tdOtherAnswer_]');

    questions.forEach(q => {
        q.style.display = '';
        q.classList.remove('current-question');
    });
    answers.forEach(a => a.style.display = '');
    otherAnswers.forEach(a => a.style.display = '');
    otherAnswers.forEach(a => a.style.minHeight = '');//code:20012025 1:00pm

    // Hide all navigation buttons
    document.querySelectorAll('[id^=navigationBtns]').forEach(nav => {
        nav.style.display = 'none';
    });
    // showPreviewQuestions();
}
//2025 code: 16012025 3:00pm
// Update existing navigation functions
function previousQuestion(currentQID) {
    if (isQuestionByQuestionMode) {
        if (currentQID > 0) {
            currentQuestionIndex = currentQID - 1;
            showQuestionAtIndex(currentQuestionIndex);
        }
    } else {
        // Original previous question behavior
        const previousQID = currentQID - 1;
        var previousElement = document.getElementById("question-" + previousQID);
        if (previousElement) {
            previousElement.focus();
            questionNM(currentQID);
            questionBG(previousQID);
            //previousElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
            availExamsInner.scrollTop = previousElement.offsetTop;
            //window.scrollTo(0, 0);
        }
    }
}
//2025 code: 16012025 3:00pm
function nextQuestion(currentQID) {
    if (isQuestionByQuestionMode) {
        const nextIndex = currentQID + 1;
        if (document.getElementById("question-" + nextIndex)) {
            currentQuestionIndex = nextIndex;
            showQuestionAtIndex(currentQuestionIndex);
        }
    } else {
        // Original next question behavior
        const nextQID = currentQID + 1;
        if (document.getElementById("question-" + nextQID)) {
            questionNM(currentQID);
            questionBG(nextQID);
            //document.getElementById("question-" + nextQID).scrollIntoView(); 
            availExamsInner.scrollTop = document.getElementById("question-" + nextQID).offsetTop;
            //window.scrollTo(0, 0);
        }
    }
}
//2025 code: 16012025 3:00pm
// Update the questionBG and questionNM functions to work with both modes
const originalQuestionBG = questionBG;
questionBG = function (QID) {
    if (!isQuestionByQuestionMode) {
        originalQuestionBG(QID);
    }
};
//2025 code: 16012025 3:00pm
const originalQuestionNM = questionNM;
questionNM = function (QID) {
    if (!isQuestionByQuestionMode) {
        originalQuestionNM(QID);
    }
};

//document.addEventListener('DOMContentLoaded', function () {
//    // Define media query
//    const mediaQuery = window.matchMedia('(max-width: 1250px)');

//    // Function to handle media query changes
//    function handleMediaQueryChange(event) {
//        // const bigTD = document.getElementById('bigTD');
//        const bigTDs = document.querySelectorAll('.bigTD');

//        if (bigTDs) { // Check if the element exists
//            if (event.matches) {
//                // bigTD.classList.add('blockTD');
//                bigTDs.forEach(function (bigTD) {
//                    bigTD.classList.add('blockTD'); // Apply class to each element
//                });
//                //c_log('Viewport is 1250px or less.');
//            } else {
//                // bigTD.classList.remove('blockTD');
//                bigTDs.forEach(function (bigTD) {
//                    bigTD.classList.remove('blockTD'); // Apply class to each element
//                });
//                //c_log('Viewport is more than 1250px.');
//            }
//        }
//    }

//    // Initial check
//    handleMediaQueryChange(mediaQuery);

//    // Listen for changes in the media query
//    mediaQuery.addEventListener('change', handleMediaQueryChange);
//});





//code: 20240828: 0400pm Define thefocusLastAnsweredQuestion() Function
function focusLastAnsweredQuestion(answers) {
    // //c_log(jsMgtExam);
    // //c_log("EVIDENCEEEEEE!!!!!!:",answers);
    // const flattenedAnswers = answers.flat();

    // // Log each answer object to check its structure
    // flattenedAnswers.forEach((answer, index) => {
    //     //c_log("Answer" + index + ":", answer);
    // });

    // // Filter to get only the answers that belong to the current user
    // const userAnswers = flattenedAnswers.filter(answer => answer.isMine === true);
    // //c_log("User's answers:", userAnswers);

    // if (userAnswers.length === 0) {
    //     //c_log("No answers found for the current user.");
    //     return;
    // }
    // //code: 20240828: 0400pm Sort by date first then by time
    // userAnswers.sort((a, b) => {
    //     const dateA = new Date(a.DTCreated);
    //     const dateB = new Date(b.DTCreated);

    //     if (dateA.getTime() !== dateB.getTime()) {
    //         return dateB.getTime() - dateA.getTime();
    //     }

    //     return 0; //code: 20240828: 0400pm Dates are equal, maintain original order
    // });

    // //userAnswers.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
    // ////c_log(userAnswers);

    // const lastAnsweredQuestionID = userAnswers[0]?.LineID;
    // const lastAnsweredQuestionNum = userAnswers[0]?.QuestNum;
    // //c_log("Last answered question ID:", lastAnsweredQuestionID);

    // //c_log("Last answered question Num:", lastAnsweredQuestionNum);

    // const index = jsMgtExam.findIndex(object => object.LineID === lastAnsweredQuestionID);//code: 20240828: 0400pm get the index of the related question
    // //c_log(index);
    // //const QnumSuffix = (parseInt(lastAnsweredQuestionNum.trim().slice(1)) - 1).toString();
    //// //c_log(QnumSuffix);

    // if (lastAnsweredQuestionID) {
    //     //const questionElement = document.getElementById("question-" + QnumSuffix);
    //     const questionElement = document.getElementById("question-" + index);//code: 20240828: 0400pm fetch the question
    //     if (questionElement) {
    //         questionElement.focus();
    //         questionElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
    //         //c_log("Focused question element:", questionElement);
    //     }
    // }
}



//function focusLastAnsweredQuestion(answers) {
//    //c_log(answers);
//    const flattenedAnswers = answers.flat();

//    // Log each answer object to check its structure
//    flattenedAnswers.forEach((answer, index) => {
//        //c_log("Answer" + index + ":", answer);
//    });

//    // Filter to get only the answers that belong to the current user
//    const userAnswers = flattenedAnswers.filter(answer => answer.isMine === true);
//    //c_log("User's answers:", userAnswers);

//    if (userAnswers.length === 0) {
//        //c_log("No answers found for the current user.");
//        return;
//    }

//    userAnswers.sort((a, b) => {
//        const dateA = new Date(a.DTCreated);
//        const dateB = new Date(b.DTCreated);

//        if (dateA.getTime() !== dateB.getTime()) {
//            return dateB.getTime() - dateA.getTime(); // Sort by date first
//        }

//        return 0; // Dates are equal, maintain original order
//    });

//    const lastAnsweredQuestionID = userAnswers[0]?.LineID;
//    const lastAnsweredQuestionNum = userAnswers[0]?.QuestNum;
//    //c_log("Last answered question ID:", lastAnsweredQuestionID);
//    //c_log(lastAnsweredQuestionNum.slice(1));
//    const QnumPref = (parseInt(lastAnsweredQuestionNum.slice(1)) - 1).toString();
//    //c_log(QnumPref);

//    if (lastAnsweredQuestionID) {
//        const questionElement = document.getElementById("question-" + QnumPref);
//        /// //c_log(questionElement);
//        if (questionElement) {
//            questionElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
//            //c_log("Focused question element:", questionElement);
//        }
//    }
//}


/////////////////////////////////////////////////////////////////////////////////////////////////////////////
//2024 code: 07232024 5:00pm
//let currentStickyQID = null;


//function previousQuestion(currentQID) {//2024 code: 07232024 5:00pm

//    const previousQID = currentQID - 1;
//    var previousElement = document.getElementById("question-" + previousQID);

//    if (previousElement) {

//        previousElement.focus();
//        questionNM(currentQID);
//        questionBG(previousQID);
//        previousElement.scrollIntoView({ behavior: 'smooth', block: 'start' });
//        window.scrollTo(0, 0);


//    }
//}


//function nextQuestion(currentQID) {//2024 code: 07232024 5:00pm
//    const nextQID = currentQID + 1;
//    if (document.getElementById("question-" + nextQID)) {
//        questionNM(currentQID);
//        questionBG(nextQID);
//        document.getElementById("question-" + nextQID).scrollIntoView();
//        window.scrollTo(0, 0);
//        ////c_log("Nextttt")
//        // document.getElementById("question-" + nextQID).focus();
//    }
//}

//function questionBG(QID) {//2024 code: 07232024 5:00pm
//    if (currentStickyQID !== null) {
//        questionNM(currentStickyQID);
//    }
//    if (isDocumentActive || isScoringActive || isLikelihoodActive || isControlActive || isRecommendedRemediationActive || isReferenceSourceActive) {
//        currentStickyQID = QID;
//        const questionElement = document.getElementById("question-" + QID);
//        questionElement.classList.add('floating-modal');

//        //navigationBtns
//        const navigationButtons = document.getElementById("navigationBtns" + QID);
//        navigationButtons.style.display = "flex";
//        navigationButtons.classList.add('floating-modal');

//    }
//}

//function questionNM(QID) {//2024 code: 07232024 5:00pm
//    if (QID !== currentStickyQID) return;

//    const questionElement = document.getElementById("question-" + QID);
//    questionElement.classList.remove('floating-modal');
//    const navigationButtons = document.getElementById("navigationBtns" + QID);
//    navigationButtons.style.display = "none";
//}

////2024 code: 20240821 4:00pm
//function debounce(func, delay) {
//    let debounceTimer;
//    return function (...args) {
//        clearTimeout(debounceTimer);
//        debounceTimer = setTimeout(() => func.apply(this, args), delay);
//    };
//}
////2024 code: 20240821 4:00pm
//window.debouncedQuestionBG = debounce(questionBG, 250);
//window.debouncedQuestionNM = debounce(questionNM, 250);




// ============================================================
// SECTION: per-line scoring reset, exam document management (list/delete/upload), CMS-file picker popup
// ============================================================
function mgtResetScoringLine(strLineID, LineID) {
    var fldLen = (MGTScoringTypes.length > 0) ? MGTScoringTypes[0]["FldLength"] : 0;
    for (var f = 0; f < fldLen; f++) {
        var ix = (f + 1);

        var FldVals = MGTScoringTypes[0]["Fld" + ix + "Vals"].split(",");
        for (var ff = 0; ff < FldVals.length; ff++) {
            var FldVal = FldVals[ff];

            document.getElementById("auditScoring_Fld" + ix + "_" + FldVal + "_" + strLineID).checked = false;
        }
    }
    //code: 240322:503p
    CalcNetScores(LineID, ix);
}

function MGTPopDocs() {
    var js = jsMgtDocs;
    console.log("doc req", jsMgtDocs);

    var clas = document.getElementsByClassName("mgtDocSection");
    for (var i = 0; i < clas.length; i++) {
        clas[i].innerHTML = "";
    }

    var docreqs = [];
    curExamDocs = [];

    for (var i = 0; i < js.length; i++) {
        var strLineID = js[i].LineID.replace(/-/g, "");
        var strDocReqID = js[i].DocReqID.replace(/-/g, "");
        var xCID = js[i].xCID, ExamID = js[i].ExamID, LineID = js[i].LineID, DocReqID = js[i].DocReqID;

        console.log("doc req", js[i], { indexof: docreqs.indexOf(DocReqID), docreq: js[i].Document_Request });

        if (docreqs.indexOf(DocReqID) == -1 && js[i].Document_Request != null) {
            docreqs.push(DocReqID);
            curExamDocs.push(DocReqID);

            var sect = document.getElementById("answerDocs_" + strLineID);
            xsection(sect, [
                "div|class=docrequest shadowSection|style=padding:5px; font-weight:bold|Document Request: " + js[i].Document_Request +
                ////code:so 20240705 12:11pm; added the plusBtn class
                "|||button|class=longblueButton pad10 plusBtn|style=float:right|onclick=MGTUploadDocs(" + xCID + ",'" + ExamID + "','" + LineID + "','" + DocReqID + "')|+",
                "div|id=docReq_" + strDocReqID + "|style=padding:10px"
            ]);

            var xx = js.filter(d => d.DocReqID == DocReqID && d.FID != null);
            for (var ii = 0; ii < xx.length; ii++) {
                var dr = xx[ii];
                //////c_log("docs", dr);
                try {
                    var subsect = document.getElementById("docReq_" + strDocReqID);
                    var icon = (dr.LoadedByCID == myCID) ? "document-white.png" : "file-receiving.png";

                    var docFID = (dr.LinkedFID != null) ? dr.LinkedFID : dr.FID;
                    //var docFIDType = (dr.LinkedFID != null) ? "Main" : "Application";
                    var docFIDType = "Application";
                    var onclick = "reportLoadFiles(" + docFID + ",'" + dr.Filename + "','" + dr.FileType + "')";

                    //////c_log("docs", dr.Filename);

                    xsection(subsect, [
                        "div|id=docReq_" + dr.FID +
                        "|||label|class=redlink|onclick=delExamDoc(" + dr.FID + ")|x" +
                        "|||label|style=width:10px" +
                        "|||label|icon=" + icon + "|class=cursor|onclick=" + onclick + "|" + dr.Filename,
                        "div|id=docReq2_" + dr.FID + "|style=font-weight:bold; padding:left:10px; padding:5px|Loaded By: " + dr.LoadedByName + " with " + dr.LoadedByCompany + " on " + convertDT(dr.DTCreated),
                    ]);
                } catch (ex) {
                    ////c_log("docs", ex)
                }
            }
        }
    }
}

function delExamDoc(fid, go) {
    if (!go) {
        xconfirm("Are you sure you want to remove this file from the application?", null, "delExamDoc(" + fid + ",true)");
    } else {
        xconfirm();
        getData(null, newFormData("_MgtDeleteFormDoc", { fid: fid }), function (vr) {
            refreshOFiles();
            var x = document.getElementById("docReq_" + fid);
            var xx = document.getElementById("docReq2_" + fid);
            x.parentElement.removeChild(x);
            xx.parentElement.removeChild(xx);
        });
    }
}

function MGTUploadDocs(xCID, ExamID, LineID, DocReqID, fromPCorCMS) {
    MGTUploadDocs_Params = [xCID, 0, ExamID, LineID, DocReqID];
    ////c_log("jsExamCMSFiles", jsExamCMSFiles);
    

    if (!fromPCorCMS) {
        getData(null, newFormData("_GetAltUID", { xcid: xCID }), function (vr) {
            var xx = jparse(vr);
            var xUID = 0, xCompany = "";
            if (xx.length > 0) {
                xUID = xx[0].UID;
                xCompany = xx[0].Company;
            }

            var elems = [
                "div|class=hdr|style=background-color:whitesmoke|Attach a Document",
                "hr", "br",
                "div|style=display:" + ((myCID == xCID || xx.length == 0) ? "none" : "") + "|||input|type=checkbox|id=cbUseToggleAcct|checked=true|value=" + xUID +
                "|||label|class=padLeft10|style=font-size:10px; font-weght:normal; color:black|Use your account for [" + xCompany + "]|||br|||br",
                "",
                "button|id=btnExamUploDocs1|class=longblueButton|style=width:300px|onclick=MGTUploadDocs(" + prms([xCID, ExamID, LineID, DocReqID, 1]) + ")|From PC",
                "br", "br",
                "button|id=btnExamUploDocs2|class=longblueButton|style=width:300px|onclick=MGTUploadDocs(" + prms([xCID, ExamID, LineID, DocReqID, 2]) + ")|From CMS"
            ];
            xconfirm(null, elems, "cancel");
        });
    } else if (fromPCorCMS == 1) {
        var xUID = (cbUseToggleAcct.checked) ? cbUseToggleAcct.value : 0;
        xconfirm();
        try { inputMGTUpload.parentElement.removeChild(inputMGTUpload); } catch (e) { };
        xsection(PageContainer, [
            "input|type=file|id=inputMGTUpload|multiple=true|style=display:none|onchange=MGTUploadDocsGO(" + xCID + "," + xUID + ",'" + ExamID + "','" + LineID + "','" + DocReqID + "')"
        ]);
        inputMGTUpload.click();
    } else if (fromPCorCMS == 2) {
        var xUID = (cbUseToggleAcct.checked) ? cbUseToggleAcct.value : 0;
        MGTUploadDocs_Params[1] = xUID;
        xconfirm();

        selectedCMSFiles = [];
        PopUp("Select from CMS Files", [xCID, xUID, ExamID, LineID, DocReqID, fromPCorCMS], null, null, ["400px", "900px"]);
    };

        //btnExamUploDocs1.disabled = true;
        //btnExamUploDocs2.disabled = true;

        //ftnGetCMSFiles(xCID, function () {
        //    alert("here");
        //    btnExamUploDocs1.disabled = false;
        //    btnExamUploDocs2.disabled = false;
        //});
   
}


var scfExpandCollpase = false;
var scfECArray = [];
function SelectfromCMSFiles(main, arr) {
    scfExpandCollpase = false;
    scfECArray = [];

    PopUpOpt(main, "button|class=blueButton|id=btnSubmitCMSFiles|onclick=submitCMSFiles(" + prms(arr) + ")|style=display:none|Submit")
    xsection(main, [
        "div|style=text-align:right; padding-right:5px" +
        "|||label|icon=magGlassLtBlue.png|class=padRight10|Search:" +
        "|||input|id=txtSearchCMSFiles|onkeyup=SearchCMSFiles(event)",
        "div|id=scfExpandAll|class=smhdr cursor|onclick=scf_display(0)|style=background-color:whitesmoke; border-bottom:solid .5px silver; height:15px; padding-left:5px;" +
        "|||img|id=scfExpandCollpaseImgFalse|src=expandCollapseDOWN.png|style=width:12px; height:10px; display:" + ((!scfExpandCollpase) ? "" : "none") +
        "|||img|id=scfExpandCollpaseImgTrue|src=expandCollapseUP.png|style=width:12px; height:10px; display:" + ((scfExpandCollpase) ? "" : "none"),
        "div|id=SelectCMSFiles_Main|style=height:calc(100% - 50px);"
    ]);
    txtSearchCMSFiles.focus();

    ////c_log("jsExamCMSFiles", jsExamCMSFiles);
    SelectCMSFilesGO();
}

function scf_display(fdrid) {
    if (fdrid == 0) {
        scfECArray = [];
        scfExpandCollpase = (scfExpandCollpase) ? false : true;
        document.getElementById("scfExpandCollpaseImgFalse").style.display = (scfExpandCollpase) ? "none" : "";
        document.getElementById("scfExpandCollpaseImgTrue").style.display = (!scfExpandCollpase) ? "none" : "";
        var cls = document.getElementsByClassName("scf_dv");
        for (var i = 0; i < cls.length; i++) {
            cls[i].style.display = (scfExpandCollpase) ? "" : "none";
            if (scfExpandCollpase)
                scfECArray.push(cls[i].id);
        }

    } else {
        var dv = document.getElementById("scf_dv_" + fdrid);

        if (dv) {
            var ix = scfECArray.indexOf(dv.id);
            if (ix > -1)
                scfECArray.splice(ix, 1);

            var dsp = (dv.style.display == "none") ? "" : "none";
            dv.style.display = dsp;

            if (dsp == "")
                scfECArray.push(dv.id);
        }
    }
}


function SearchCMSFiles(e) {
    if (e.keyCode == 13 || txtSearchCMSFiles.value == "") { SelectCMSFilesGO(); }
}

var usedFiles = [];
function SelectCMSFilesGO() {
    try {
        SelectCMSFiles_Main.innerHTML = "";
        SelectCMSFiles_Main.style.overflow = "auto";
        var main = SelectCMSFiles_Main;

        var x = MGTUploadDocs_Params;

        var jsUsedFiles = jsOFiles.filter(d => d.MGTxCID == x[0] && d.MGTExamID == x[1] && d.MGTLineID == x[2] && d.MGTDocReqID == x[3]);
        for (var i = 0; i < jsUsedFiles.length; i++) {
            usedFiles.push(jsUsedFiles[i].MGTFID);
        }

        var js = jsExamCMSFiles;
        console.log("err", js);
        //execute search
        var srch = txtSearchCMSFiles.value.trim();
        if (srch != "") {
            js = js.filter(d =>
                d.Folder.toLowerCase().indexOf(srch.toLowerCase()) > -1 ||
                d.Filename.toLowerCase().indexOf(srch.toLowerCase()) > -1
            );
        }


        var jsf = jsFolders.filter(d => d.FdrID > 0);

        //set maxTier
        var maxTier = 1;
        for (var i = 0; i < jsf.length; i++) {
            maxTier = (maxTier < jsf[i].FdrIDs.split(",").length) ? jsf[i].FdrIDs.split(",").length : maxTier;
        }

        //build folders & files
        for (var i = 0; i < maxTier; i++) {
            var Tier = i + 1;
            var fdrs = jsf.filter(d => d.FdrIDs.split(",").length == Tier);

            for (var ii = 0; ii < fdrs.length; ii++) {
                var xx = fdrs[ii];
                var sect = (Tier == 1) ? main : document.getElementById("scf_dv_" + xx.Parent);
                
                //build folder
                xsection(sect, [
                    "div|style=padding-left:" + ((30 * i) + 10) + "px|class=scf_fdrs|id=scf_fdr_" + xx.FdrID +
                    "|||div|id=scf_xfdr_" + xx.FdrID + "|style=position:relative;" +
                    "|||append|label|class=cursor|onclick=scf_display(" + xx.FdrID + ")|icon.id=scf_img_" + xx.FdrID + "|icon.name=scf_img|icon=folder-manilla-empty.png|" + xx.Folder,

                    "div|style=padding-left:" + ((30 * i) + 10) + "px;|||div|style=display:" + ((scfECArray.indexOf("scf_dv_" + xx.FdrID) > -1) ? "" : "none") + "|class=scf_dv|id=scf_dv_" + xx.FdrID
                ]);

                //build files
                var fils = js.filter(d => d.FdrID == xx.FdrID);
                for (var iii = 0; iii < fils.length; iii++) {
                    var fil = fils[iii];
                    var clr = (usedFiles.indexOf(fil.FID) > -1) ? "lightgreen" : "";

                    //set folder icons not empty
                    var fdrids = fil.FdrIDs.split(",");
                    for (var ff = 0; ff < fdrids.length; ff++) {
                        document.getElementById("scf_img_" + fdrids[ff]).src = "images/folder-manilla.png";
                    }

                    //write file
                    nsection("scf_dv_" + xx.FdrID, [
                        "div|style=padding-left:" + ((30 * i) + 40) + "px;" +
                        "|||label|icon=document-white.png|class=navlink|style=background-color:" + clr +
                        "|class=CMSFileFID_" + fil.FID +
                        "|onclick=SelectCMSFilesHiLite(" + fil.FID + ")|" + fil.Filename
                    ]);
                }
            }
        }

        var fdrs = document.getElementsByName("scf_img");        
        for (var i = 0; i < fdrs.length; i++) {
            var xx = fdrs[i];

            if (xx.src.indexOf("empty") > -1) {
                var fdrid = xx.id.split("_")[2];
                var fdr = document.getElementById("scf_fdr_" + fdrid);
                var dv = document.getElementById("scf_dv_" + fdrid);
                console.log("err img", fdrid, fdr, dv);

                fdr.style.display = "none";
                dv.style.display = "none";
            }
        }

        //expand all
        scf_display(0);

    } catch (ex) {
        console.log("err", ex);
    }

}


function SelectCMSFilesHiLite(FID) {
    //add or remove FID from selected array
    if (FID != null) {
        var ix = selectedCMSFiles.indexOf(FID);
        if (ix == -1) { selectedCMSFiles.push(FID); } else { selectedCMSFiles.splice(ix, 1); }
    }

    //set submit button when files are selected
    btnSubmitCMSFiles.style.display = (selectedCMSFiles.length == 0) ? "none" : "";

    //remove all hilites
    for (var i = 0; i < jsExamCMSFiles.length; i++) {
        var x = document.getElementsByClassName("CMSFileFID_" + jsExamCMSFiles[i].FID);
        for (var ii = 0; ii < x.length; ii++) {
            var xx = x[ii];
            xx.style.backgroundColor = "white";
            xx.style.color = "black";
        }
    }

    //hilite selected files
    for (var i = 0; i < selectedCMSFiles.length; i++) {
        var x = document.getElementsByClassName("CMSFileFID_" + selectedCMSFiles[i]);
        for (var ii = 0; ii < x.length; ii++) {
            var xx = x[ii];
            xx.style.backgroundColor = "green";
            xx.style.color = "white";
        }
    }

    //hilite used files
    for (var i = 0; i < usedFiles.length; i++) {
        var x = document.getElementsByClassName("CMSFileFID_" + usedFiles[i]);
        for (var ii = 0; ii < x.length; ii++) {
            var xx = x[ii];
            xx.style.backgroundColor = "yellow";
            xx.style.color = "black";
        }
    }
}

function submitCMSFiles(xCID, xUID, ExamID, LineID, DocReqID, fromPCorCMS) {
    console.log("_MGTExamAttachCMSDoc", { xcid: xCID, examid: ExamID, lineid: LineID, docreqid: DocReqID, FIDS: selectedCMSFiles.join(",") });
    var data = newFormData("_MGTExamAttachCMSDoc",
        { xcid: xCID, xuid: xUID, examid: ExamID, lineid: LineID, docreqid: DocReqID, FIDS: selectedCMSFiles.join(",") }
    );
    getData(null, data, function (vr) {
        closePopUp("Select from CMS Files");

        jsMgtDocs = jparse(vr);
        MGTPopDocs();
        refreshOFiles();

        //code:20240522:1133am - remove hover elem when done
        var fh = document.getElementsByClassName("FileHover");
        for (var i = 0; i < fh.length; i++) {
            PageContainer.removeChild(fh[i]);
        }
    });
}

function MGTUploadDocsGO(xCID, xUID, ExamID, LineID, DocReqID, ix) {
    ix = (ix == null) ? 0 : ix;
    var fils = inputMGTUpload.files;

    if (ix < fils.length) {
        var fil = fils[ix];

        var data = newFormData("_MGTExamUploadDoc", { xcid: xCID, xuid: xUID, examid: ExamID, lineid: LineID, docreqid: DocReqID });
        data.append(fil.name, fil);

        getData("#adHocAttach", data, function (vr) {
            jsMgtDocs = jparse(vr);
            ix++;
            MGTUploadDocsGO(xCID, xUID, ExamID, LineID, DocReqID, ix);
        });
    } else {
        MGTPopDocs();
        refreshOFiles();
    }
}

// ============================================================
// SECTION: scoring defaults/population, answer editing (MGTEditAnswer/MGTPopAnswers), net-score calc, JS report generation
// ============================================================
function MGTSetDefaultScores(go, lineid) {
    if (!go)
        xconfirm(null, [
            "div|This option will set the remaining unscored lines to the values from this line.",
            "br",
            "div|Do you want to continue?"
        ], "MGTSetDefaultScores(true, '" + lineid + "')");

    else
        getData(null, newFormData("_SetExamDefaultScores", { examid: MgtExamID, xcid: MgtXCID, lineid: lineid }), function (vr) {
            console.log("err", "_SetExamDefaultScores", { examid: MgtExamID, xcid: MgtXCID, lineid: lineid }, vr);
            xconfirm();
            MGTPopScores();
        });
}


function MGTPopScores(onDone) {
    var sc = mgtSnapMap(["_MgtGetExamScores"], [{ examid: MgtExamID, xcid: MgtXCID }]);
    getData(null, newFormData(sc[0][0], sc[1][0]), function (vr) {
        var js = jparse(vr);
        //code:jk-20240904:109pm - set json of scores
        jsMGTScores = js;

        for (var i = 0; i < js.length; i++) {
            var LineID = js[i]["LineID"].replace(/-/g, "");
            var FldLen = MGTScoringTypes[0]["FldLength"];
            var elems = [], vals = [];
            for (f = 0; f < FldLen; f++) {
                var ix = (f + 1);
                elems.push(document.getElementsByName("auditScoring_Fld" + ix + "_" + LineID))
                vals.push(js[i][MGTScoringTypes[0]["Fld" + ix]]);
            }

            for (var e = 0; e < elems.length; e++) {
                for (var ii = 0; ii < elems[e].length; ii++) { if (elems[e][ii].value * 1 == vals[e]) { elems[e][ii].checked = true } }
            }

            var valNet = js[i]["NetScore"];
            var Net0 = document.getElementById("auditHdrScoring_Net_0_" + LineID);
            var Net1 = document.getElementById("auditHdrScoring_Net_1_" + LineID);
            var reset = document.getElementById("resetScoring_" + LineID);
            var def = document.getElementById("defaultScoring_" + LineID);

            if (Net0 != null) {
                if (valNet > 0) {
                    var xjs = jsMgtScoring.filter(d => between(valNet, d.low, d.high));
                    Net0.innerHTML = "Net Score: " + valNet;
                    Net1.innerHTML = xjs[0]["text"];
                    reset.innerHTML = "[x]";
                    def.innerHTML = "[+]";
                } else {
                    Net0.innerHTML = "Net Score ";
                    Net1.innerHTML = "";
                    reset.innerHTML = "";
                    def.innerHTML = "";
                }
            }
        }
        if (onDone) onDone();
    });
}

function MgtEditAnswer(ix, id, q, strLineID_IX) {
    showOpts("Edit Exam Response", [ix, id, q, strLineID_IX]);
}
function EditExamResponse(main, arr) {
    var js = jsMgtAnswers[arr[0]].filter(d => d.AnswerID == arr[1]);

    nsection("soSubmit", [
        "button|class=blueButton|onclick=MGTEditAnswer(0," + [arr[0], arr[1]].join(",") + ")|Save",
        "label|style=width:10px|",
        "button|class=blueButton|onclick=MGTEditAnswer(1," + [arr[0], arr[1]].join(",") + ", null, '" + arr[3] + "')|Archive",
    ]);

    nsection("optMain", [
        "textarea|id=txtEditExamResp|style=width:100%;height:400px;resize:none|" + js[0][arr[2]]
    ]);
}

function MGTEditAnswer(ea, ix, id, go, strLineID_IX) {
    if (!go) {
        xconfirm("Are you sure you want to " + ((ea == 0) ? "update" : "archive") + " this response?",
            null, "MGTEditAnswer(" + [ea, ix, id, true].join(",") + ", '" + strLineID_IX + "')");
    } else {
        xconfirm();
        if (ea == 0) {
            var data = newFormData("_MgtUpdateAnswer",
                { examid: MgtExamID, xcid: MgtXCID, standardHeatmap: ix, answerid: id, answer: txtEditExamResp.value }
            );

            getData(null, data, function (vr) {
                opts(false);
                MGTPopAnswers();
            });
        }
        else {
            var data = newFormData("_MgtArchiveAnswer",
                { examid: MgtExamID, xcid: MgtXCID, standardHeatmap: ix, answerid: id }
            );

            getData(null, data, function (vr) {
                try {
                    var fld = document.getElementById("answer_" + strLineID_IX);
                    var cbfld = document.getElementById("cb_answer_" + strLineID_IX);
                    fld.style.display = "";
                    cbfld.checked = false;
                    cbfld.style.display = "none";
                } catch (ex) {
                    //////c_log(strLineID_IX, ex);
                }

                opts(false);
                MGTPopAnswers();
            });
        }
    }
}

function MGTPopAnswers(passedLineID, passedQNum, onDone) {
    var passedfld, passedfldDetails;
    //passedLineID = null;
    ////c_log("xxxmpa", passedLineID, passedQNum);

    jsRemediationsStore = [];
    var ad = document.getElementsByClassName("answerDetails");
    if (!passedLineID) {
        for (var i = 0; i < ad.length; i++) {
            ad[i].innerHTML = "";
        }
    } else {
        var thisAD = document.getElementById("answerDetails_" + passedLineID.replace(/-/g, "") + "_" + passedQNum);
        thisAD.innerHTML = "";
        ////c_log("thisfld thisad", thisAD);
    }

    var arr = mgtSnapMap(
        ["_MgtGetExamAnswers", "_MgtGetExamAnswers"],
        [{ examid: MgtExamID, xcid: MgtXCID, pass: 0 }, { examid: MgtExamID, xcid: MgtXCID, pass: 1 }]
    );

    RunMultiSP(arr[0].join(","), arr[1], function (js) {
        jsMgtAnswers = js;
        ////c_log(jsMgtAnswers);
        ////c_log("xxxpop", passedLineID, passedQNum, js);

        ////code:jk-20240904:109pm - replaced with function below, "FocusLastQuestion()"
        //focusLastAnsweredQuestion(jsMgtAnswers, passedQNum);//code: 20240819: 0400pm Invoke the focusLastAnsweredQuestion() Function

        //mgt answer rows grouped by LineID once (was a js[1].filter for every answer x layer)
        var mgtRowsByLine = new Map(), mgtRows = js[1] || [];
        for (var r = 0; r < mgtRows.length; r++) {
            var rLine = mgtRows[r].LineID;
            if (!mgtRowsByLine.has(rLine)) mgtRowsByLine.set(rLine, []);
            mgtRowsByLine.get(rLine).push(mgtRows[r]);
        }

        //loop through both member and mgt answers

        for (var internal = 0; internal < 2; internal++) {
            ////c_log("xxxpop1", "internal=", internal)

            for (var i = 0; i < js[internal].length; i++) {
                try {
                    var xjs = js[internal][i];
                    ////c_log("xxxpop1", xjs["AnswerID"], xjs)

                    var thisLineID = xjs["LineID"];
                    var strLineID = xjs["LineID"].replace(/-/g, "");

                    ////c_log("get ansby", xjs);

                    var ansBy = xjs["AnsweredBy"] + " [" + convertDT(xjs["DTCreated"]) + "]";
                    ansBy = (xjs["DTUpdated"] != null) ? xjs["AnsweredBy"] + " [" + convertDT(xjs["DTUpdated"]) + "]" : ansBy;
                    var ansID = xjs["AnswerID"];
                    var UpdAns = (xjs["Updated"] == null) ? "Answered By: " : "Edited By: ";
                    var ansColor = (xjs.isMine) ? "#D5F6CE" : "#D7EBF6";

                    //////c_log("wtf", js[internal].filter(d => d.LineID == thisLineID));

                    ////c_log("xxxpop2", ansID, xjs)

                    if (internal == 0) {//member answers
                        if (passedLineID == null || (passedLineID == thisLineID && passedQNum == 0)) {
                            ////c_log("xxxpop", ansID, xjs["Answer"].replace(/\r?\n|\r/g, "<br>"));

                            var ans = xjs["Answer"].replace(/=/g, "~").replace(/\|/g, " ").replace(/\r?\n|\r/g, "<br>");
                            var fld = document.getElementById("answer_" + strLineID + "_0");
                            var fldD = document.getElementById("answerDetails_" + strLineID + "_0");
                            fld.value = "";

                            if (ans != null && ans != "") {
                                var stOver = "height:17px;width:17px;cursor:pointer;background-color:lightgreen";
                                var stOut = "height:17px;width:17px;cursor:pointer;";

                                nsection("answerDetails_" + strLineID + "_0", [
                                    "label|icon=edit2.png|icon.style=" + stOut +
                                    "|icon.onclick=MgtEditAnswer(" + internal + "," + ansID + ",'Answer')|" +
                                    "icon.onmouseover=divAnswer_" + ansID + "_icon.setAttribute('style', '" + stOver + "')|" +
                                    "icon.onmouseout=divAnswer_" + ansID + "_icon.setAttribute('style', '" + stOut + "')|" +
                                    "id=divAnswer_" + ansID + "|style=padding-left:10px|" + ans + "|||" +
                                    "div|id=divAnswer_" + ansID + "_AnsBy|style=background-color:" + ansColor + "; padding-left:10px; padding:5px|" + UpdAns + ansBy
                                ]);

                                document.getElementById("divAnswer_" + ansID).className = "padLeft10";
                                document.getElementById("divAnswer_" + ansID + "_AnsBy").style.backgroundColor = ansColor;
                            }
                        }
                    } else {
                        //////c_log("MGTAuditLayers", MGTAuditLayers);
                        var ansPopulated = [];

                        for (var ii = 0; ii < MGTAuditLayers.length; ii++) {//mgt answers
                            var ix = ii + 1;

                            var isRemediation = MGTAuditLayers[ii]["Remediation"];
                            var ans = js[1][i][MGTAuditLayers[ii]["Name"]];
                            var ans2 = "";

                            if (isRemediation) {
                                jsRemediationsStore.push({ ModNum: xjs.ModNum, QuestNum: xjs.QuestNum, strLineID: strLineID, Name: MGTAuditLayers[ii]["Name"], Answer: ans });
                            }

                            if (passedLineID == null || (passedLineID == thisLineID && passedQNum == ix)) {

                                //////c_log("wtf", thisLineID, js[1]);
                                try {
                                    ans2 = (mgtRowsByLine.get(thisLineID) || []).filter(d =>
                                        d[MGTAuditLayers[ii]["Name"]] != null &&
                                        d[MGTAuditLayers[ii]["Name"]] != ""
                                    )[0][MGTAuditLayers[ii]["Name"]];
                                } catch (ex) {
                                    //////c_log("wtf", ex);
                                }

                                var fld = document.getElementById("answer_" + strLineID + "_" + ix);
                                var cbfld = document.getElementById("cb_answer_" + strLineID + "_" + ix);
                                var cbfldid = (cbfld != null) ? cbfld.id : "";
                                var fldD = document.getElementById("answerDetails_" + strLineID + "_" + ix);

                                if (cbfldid != "" && ansPopulated.indexOf(cbfldid) == -1) {
                                    if (ans2 != null && ans2 != "") {
                                        ansPopulated.push(cbfldid);

                                        cbfld.style.display = "";
                                        cbfld.checked = true;
                                        fld.style.display = "none";
                                    } else {
                                        cbfld.style.display = "none";
                                        cbfld.checked = false;
                                        fld.style.display = "";
                                    }
                                    //////c_log("wtf", "ansPopulated", strLineID, ansPopulated, ans);
                                }


                                if (fld != null) {
                                    fld.value = "";

                                    if (ans != null && ans != "") {
                                        if (MGTAuditLayers[ii]["Type"] == "checkbox") {//mgt checkbox answers
                                            var cbFld = document.getElementById("cbanswer_" + strLineID + "_" + ix);
                                            if (cbFld.value == MGTAuditLayers[ii]["Name"]) {
                                                fld.checked = true;
                                                fldD.innerHTML = "Answered By: " + ansBy;
                                                fldD.className = "padLeft10 pad5";
                                                fldD.style.backgroundColor = ansColor;
                                            }
                                        } else {//mgt text answers
                                            var stOver = "height:17px;width:17px;cursor:pointer;background-color:lightgreen";
                                            var stOut = "height:17px;width:17px;cursor:pointer;";
                                            //ans = ans.replace(/\r?\n|\r/g, "<br>");
                                            ans = ans.replace(/=/g, "~").replace(/\|/g, " ").replace(/\r?\n|\r/g, "<br>");

                                            nsection("answerDetails_" + strLineID + "_" + ix, [
                                                "label|icon=edit2.png|icon.style=" + stOut +
                                                "|icon.onclick=MgtEditAnswer(" + internal + "," + ansID + ",'" + MGTAuditLayers[ii]["Name"] + "','" + strLineID + "_" + ix + "')|" +
                                                "icon.onmouseover=divAnswer_" + ansID + "_icon.setAttribute('style', '" + stOver + "')|" +
                                                "icon.onmouseout=divAnswer_" + ansID + "_icon.setAttribute('style', '" + stOut + "')|" +
                                                "id=divAnswer_" + ansID + "|class=PadLeft10|" + ans + "|||" +
                                                "div|id=divAnswer_" + ansID + "_AnsBy|class=padLeft10 pad5|" + UpdAns + ansBy
                                            ]);
                                            document.getElementById("divAnswer_" + ansID).className = "padLeft10";
                                            document.getElementById("divAnswer_" + ansID + "_AnsBy").style.backgroundColor = ansColor;
                                        }
                                    } else if (ans == "") {
                                        fldD.innerHTML = "";
                                        fldD.className = "padLeft10 pad5";
                                    }
                                }
                            }
                        }
                    }
                } catch (ex) {
                    ////c_log("xxxpopERR", ex)
                }
            }
        }

        //code:jk-20240904:109pm - function to set init focus
        //code:20261027 on the initial exam load the reveal step does the focus once the exam is visible
        if (onDone) onDone();
        else FocusLastQuestion();
    });
}

function FocusLastQuestion() {
    //code:jk-20240904:109pm - set init focus
    if (!hasFocused) {
        try {
            var LastLine = { LineID: null, DTCreated: null };

            var js = jsMgtAnswers[0].filter(d => d.isMe);
            sortJS(js, "DTCreated", true);
            if (js.length > 0)
                LastLine = { LineID: js[0].LineID, DTCreated: js[0].DTCreated };

            var js = jsMgtAnswers[1].filter(d => d.isMe);
            sortJS(js, "DTCreated", true);
            if (js.length > 0)
                if (js[0].DTCreated > LastLine.DTCreated || LastLine.DTCreated == null)
                    LastLine = { LineID: js[0].LineID, DTCreated: js[0].DTCreated };

            var js = jsMGTScores.filter(d => d.isMe);
            sortJS(js, "DTCreated", true);
            if (js.length > 0)
                if (js[0].DTCreated > LastLine.DTCreated || LastLine.DTCreated == null)
                    LastLine = { LineID: js[0].LineID, DTCreated: js[0].DTCreated };

            if (!focusElem) {
                var focusElem = document.getElementsByClassName("question_" + LastLine.LineID.replace(/-/g, ""))[0];
                focusElem.focus();
                //focusElem.scrollIntoView();
                availExamsInner.scrollTop = focusElem.offsetTop;
                //window.scrollTo(0, 0);
            }
        } catch (err) {
            //c_log("mgt answers", err);
        }
        hasFocused = true;
    }
}
//code:20240524:219pm - added class=ocInput to all onchange inputs and created this function to disable and re-enable in the Onchange function
function DisableEnableOCInputs(TF, passedLineID, passedQNum) {
    var oc = document.getElementsByClassName("ocInput");
    for (var i = 0; i < oc.length; i++) {
        oc[i].disabled = TF;
        //////c_log(oc[i]);
    }
}

function MGTAnswerOnchange(LineID, QNum, CB, runConfirm) {
    var confirmed = true;
    if (runConfirm)
        confirmed = confirm("This data will be archived.  Do you want to continue?");

    if (!confirmed) {
        document.getElementById("cb_answer_" + LineID.replace(/-/g, "") + "_" + QNum).checked = true;

    } else {
        //alert("MGTAnswerOnchange");
        var fld = document.getElementById("answer_" + LineID.replace(/-/g, "") + "_" + QNum);
        var fldDetails = document.getElementById("answerDetails_" + LineID.replace(/-/g, "") + "_" + QNum);
        var answer = fld.value;
        if (answer.length > 8000)
            xconfirm("Error:  The text may not exceed 8,000 characters");
        else {
            if (CB != null) {
                if (!fld.checked) {
                    answer = "";
                }
            }
            if (answer == "") {
                //code:20240524:239pm - remove answer details when unselected
                try {
                    fldDetails.innerHTML = "";
                    fldDetails.className = "padLeft10 pad5";
                } catch (e) { }
            }
            var strjson = { xcid: MgtXCID, ExamID: MgtExamID, LineID: LineID, QNum: QNum, Answer: answer };
            var data = newFormData("_MgtUpdateAnswers", strjson);
            //c_log(strjson);
            //MGTAnswerOnchange('971A28D2-4F4E-4F30-B3D7-ADC746EDDC07',0)
            //////c_log("xxxmpa", "exec neo_MgtUpdateAnswers 8540, " + MgtXCID + ",'" + MgtExamID + "','" + LineID + "'," + QNum + ",'" + answer + "'")

            //code:20240524:219pm - disable and reenable ocInputs before and after change
            c_log(1763, "_MgtUpdateAnswers", strjson)
            DisableEnableOCInputs(true);
            getData(null, data, function (vr) {
                c_log(1763, vr)
                DisableEnableOCInputs(false);
                ////c_log("init onchange", vr);

                MGTPopAnswers(LineID, QNum);
                if (runConfirm)
                    fld.style.display = "";

                //code:20261025 exam workflow: a remediation unchecked within an hour of being set -> offer to drop its action
                if (CB != null && answer == "" && QNum > 0) { mgtWorkflowCheckRemoval(LineID, QNum); }

                //SendEmailAlert('Exams', MgtExamID, MgtXCID);
            });
        }
    }
}

function CalcNetScores(LineID, ix) {
    var strLineID = LineID.replace(/-/g, "");
    var fldLen = MGTScoringTypes[0]["FldLength"];

    var vals = [];

    for (var f = 0; f < fldLen; f++) {
        var L = document.getElementsByName("auditScoring_Fld" + (f + 1) + "_" + strLineID);
        var valL = 0;
        for (var i = 0; i < L.length; i++) { valL = (L[i].checked) ? L[i].value * 1 : valL }

        vals.push(valL);
    }

    var data = newFormData("_MgtUpdateLMC", { ExamID: MgtExamID, LineID: LineID, xcid: MgtXCID, vals: vals.join(",") });
    getData(null, data, function (vr) {
        var js = jparse(vr).filter(d => d.LineID == LineID);
        ////c_log("net scores", js);

        var valNet = js[0]["NetScore"];
        var Net0 = document.getElementById("auditHdrScoring_Net_0_" + strLineID); //code: 20240912: 105pm
        var Net1 = document.getElementById("auditHdrScoring_Net_1_" + strLineID); //code: 20240912: 105pm
        var reset = document.getElementById("resetScoring_" + strLineID);
        var def = document.getElementById("defaultScoring_" + strLineID);

        if (valNet > 0) {
            var js = jsMgtScoring.filter(d => between(valNet, d.low, d.high));
            Net0.innerHTML = "Net Score: " + valNet;
            Net1.innerHTML = js[0]["text"];
            Net1.style.paddingLeft = "3%";
            Net1.style.paddingTop = "1%";
            reset.innerHTML = "[x]";
            def.innerHTML = "[+]";
        } else {
            Net0.innerHTML = "Net Score ";
            Net1.innerHTML = "N/A";//code: 20240912: 105pm
            reset.innerHTML = "";
            def.innerHTML = "";
        }
    });
}

function generateJSReport(callback) {
    var js = jsMgtExam;
    jsMgtReport = [];

    var hm = mgtSnapMap(["_MgtGetHeatmap"], [{ ExamID: MgtExamID }]);
    getData(null, newFormData(hm[0][0], hm[1][0]), function (vr) {
        var jsHeatmap = jparse(vr);

        if (jsHeatmap.length == 0) {
            xconfirm("Heatmap scoring has not been set up");
            if (callback) callback(false);
            return;
        }

        for (var ii = 0; ii < js.length; ii++) {
            try {
                var strLineID = js[ii]["LineID"].replace(/-/g, "");
                var heatmapStatment = jsHeatmap.filter(d => d.LineID == js[ii]["LineID"])[0]["HeatmapStatment"];

                var fldLen = (MGTScoringTypes.length > 0) ? MGTScoringTypes[0]["FldLength"] : 0;
                var vals = [];
                for (var f = 0; f < fldLen; f++) {
                    var L = document.getElementsByName("auditScoring_Fld" + (f + 1) + "_" + strLineID);
                    var valL = 0;
                    for (var i = 0; i < L.length; i++) { valL = (L[i].checked) ? L[i].value * 1 : valL; }
                    vals.push(valL);
                }

                var rems = [];
                var tmpRems = [];
                var remJS = jsRemediationsStore.filter(d => d.strLineID == strLineID);
                sortJS(remJS, js[ii], "QuestNum");

                for (var x = 0; x < remJS.length; x++) {
                    var ans = remJS[x]["Answer"];
                    var qn = js[ii]["QuestNum"];
                    var strqn = ("0000000000" + qn.toString()).slice(-10);
                    if (ans != null) {
                        tmpRems.push({ ix: strqn, qn: qn, ans: ans });
                        rems.push({ ix: x, ans: ans + " (" + qn + ")" });
                    }
                }
                sortJS(tmpRems, "ix");

                var tmp = {
                    "Assessment_Module": js[ii]["SectNum"] + " - " + js[ii]["Section"],
                    "Module_Number": js[ii]["ModNum"],
                    "Question_Number": js[ii]["QuestNum"],
                    "Heatmap_Statement": heatmapStatment,
                    "Recommended_Remediations": rems
                };
                for (var x = 0; x < vals.length; x++) {
                    tmp[MGTScoringTypes[0]["Fld" + (x + 1)]] = vals[x];
                }

                var arrNetScore = document.getElementById("auditHdrScoring_Net_0_" + strLineID).innerHTML.replace(/ /g, "").split(":");
                arrNetScore[1] = (arrNetScore.length == 1) ? 0 : arrNetScore[1];
                var NetScore = (arrNetScore.length > 0) ? (arrNetScore[1] * 1) : 0;
                NetScore = (isNaN(NetScore)) ? 0 : NetScore;
                tmp["NetScore"] = NetScore;
                tmp["strNetScore"] = NetScore + "";

                jsMgtReport.push(tmp);
            } catch (ex) { }
        }

        // If called from the zip flow, hand back control; otherwise open the heatmap UI as before
        if (callback) {
            callback(true);
        } else {
            HeatmapReport();
        }
    });
}

// ============================================================
// SECTION: heatmap report generation (form submit, HTML build, static pages, preview)
// ============================================================
function CompleteHeatmapForm_submit() {
    var OnsiteDateFrom = document.getElementById("OnsiteDateFrom").value,
        OnsiteDateTo = document.getElementById("OnsiteDateTo").value,
        OnsiteAddr1 = document.getElementById("OnsiteAddr1").value,
        OnsiteAddr2 = document.getElementById("OnsiteAddr2").value,
        OnsiteCity = document.getElementById("OnsiteCity").value,
        OnsiteState = document.getElementById("OnsiteState").value,
        OnsiteZip = document.getElementById("OnsiteZip").value,
        ExaminerNames = [], CompanyParticipants = [],
        strExaminerNames = "", strCompanyParticipants = "";

    var examiners = document.getElementsByName("cbHeatmapFormExaminers");
    var participants = document.getElementsByName("cbHeatmapFormParticipants");

    for (var i = 0; i < examiners.length; i++) {
        if (examiners[i].checked) { ExaminerNames.push(examiners[i].value); }
    }
    for (var i = 0; i < participants.length; i++) {
        if (participants[i].checked) { CompanyParticipants.push(participants[i].value); }
    }
    strExaminerNames = ExaminerNames.join("~");
    strCompanyParticipants = CompanyParticipants.join("~");

    if (OnsiteDateFrom != "" &&
        OnsiteDateTo != "" &&
        OnsiteAddr1 != "" &&
        OnsiteCity != "" &&
        OnsiteState != "" &&
        OnsiteZip != "" &&
        strExaminerNames != "" &&
        strCompanyParticipants != "" || 1 == 1) {
        var data = newFormData("_MgtUpdateForm", {
            examid: MgtExamID,
            xcid: MgtXCID,
            OnsiteDateFrom: OnsiteDateFrom,
            OnsiteDateTo: OnsiteDateTo,
            OnsiteAddr1: OnsiteAddr1,
            OnsiteAddr2: OnsiteAddr2,
            OnsiteCity: OnsiteCity,
            OnsiteState: OnsiteState,
            OnsiteZip: OnsiteZip,
            ExaminerNames: strExaminerNames,
            CompanyParticipants: strCompanyParticipants
        });
        getData(null, data, function (vr) {
            jsMgtHeatmapForm = jparse(vr)[0];
            PopUp("Complete Heatmap Form");
            HeatmapReport(true);
        });
    } else {
        xconfirm("The form has not been completed yet")
    }
}

function CompleteHeatmapForm(main) {
    xconfirm();
    if (jsMgtHeatmapForm["FormCompleted"] == null) {
        PopUp("Complete Heatmap Form");
    } else {
        var ix = main.id.split("_")[1];
        nsection("PopUp_" + ix + "_hdrOpts", [
            "label|class=padLeft10|",
            "button|class=blueButton|onclick=CompleteHeatmapForm_submit()|Submit"
        ]);

        deNullJS(jsMgtHeatmapForm);

        nsection(main.id, ["table|id=tblHeatmapForm|style=width:100%"]);
        nsection("tblHeatmapForm", [
            "tr|style=border:solid 1px gray; padding:10px|id=tblHeatmapFormTR1",
            "tr|style=border:solid 1px gray; padding:10px|id=tblHeatmapFormTR2",
            "tr|style=border:solid 1px gray; padding:10px|id=tblHeatmapFormTR3",
            "tr|style=border:solid 1px gray; padding:10px|id=tblHeatmapFormTR4",
            "tr|style=border:solid 1px gray; padding:10px|id=tblHeatmapFormTR5"]);

        nsection("tblHeatmapFormTR1", [
            "td|Client:",
            "td|" + jsMgtHeatmapForm["Agency"]
        ]);
        nsection("tblHeatmapFormTR2", [
            "td|Assessment Onsite Dates:",
            "td|id=tblHeatmapFormTR2TD1"
        ]);
        nsection("tblHeatmapFormTR2TD1", [
            "input|id=OnsiteDateFrom|type=date|value=" + fieldDT(jsMgtHeatmapForm["OnsiteDateFrom"]),
            "label|class=padLeft10 padRight10|-",
            "input|id=OnsiteDateTo|type=date|value=" + fieldDT(jsMgtHeatmapForm["OnsiteDateTo"])
        ]);

        nsection("tblHeatmapFormTR3", [
            "td|Onsite Location:",
            "td|id=tblHeatmapFormTR3TD1"
        ]);

        nsection("tblHeatmapFormTR3TD1", [
            "input|id=OnsiteAddr1|style=width:100%|placeholder=Address Line 1|value=" + jsMgtHeatmapForm["OnsiteAddr1"],
            "br",
            "input|id=OnsiteAddr2|style=width:100%|placeholder=Address Line 2|value=" + jsMgtHeatmapForm["OnsiteAddr2"],
            "br",
            "input|id=OnsiteCity|style=width:100%|placeholder=City|value=" + jsMgtHeatmapForm["OnsiteCity"],
            "br",
            "input|id=OnsiteState|style=width:100%|placeholder=State|value=" + jsMgtHeatmapForm["OnsiteState"],
            "br",
            "input|id=OnsiteZip|style=width:100%|placeholder=Zip Code|value=" + jsMgtHeatmapForm["OnsiteZip"]
        ]);

        nsection("tblHeatmapFormTR4", [
            "td|Examiners:", "td|id=tblHeatmapFormExaminers"]);

        nsection("tblHeatmapFormTR5", [
            "td|Company Participants:", "td|id=tblHeatmapFormParticipants"
        ]);

        var avail = jsMgtHeatmapForm["availExaminers"].split("~");
        var slctd = jsMgtHeatmapForm["ExaminerNames"].split("~");
        for (var i = 0; i < avail.length; i++) {
            nsection("tblHeatmapFormExaminers", [
                "input|name=cbHeatmapFormExaminers|id=cbHeatmapFormExaminers_" + i + "|type=checkbox|value=" + avail[i],
                "label|class=padLeft10|for=cbHeatmapFormExaminers_" + i + "|" + avail[i],
                "br"
            ]);
            if (slctd.indexOf(avail[i]) > -1) { document.getElementById("cbHeatmapFormExaminers_" + i).checked = true; }
        }

        var avail = jsMgtHeatmapForm["availParticipants"].split("~");
        var slctd = jsMgtHeatmapForm["CompanyParticipants"].split("~");
        for (var i = 0; i < avail.length; i++) {
            nsection("tblHeatmapFormParticipants", [
                "input|name=cbHeatmapFormParticipants|id=cbHeatmapFormParticipants_" + i + "|type=checkbox|value=" + avail[i],
                "label|class=padLeft10|for=cbHeatmapFormParticipants_" + i + "|" + avail[i],
                "br"
            ]);
            if (slctd.indexOf(avail[i]) > -1) { document.getElementById("cbHeatmapFormParticipants_" + i).checked = true; }
        }

    }
}

function HeatmapReport(go, pdfDoc) {
    xconfirm();
    ////c_log(jsMgtHeatmapForm);
    ////c_log(jsMgtReport);

    if (!jsMgtHeatmapForm["FormCompleted"]) {
        PopUp("Complete Heatmap Form", null, null, true);
    } else {
        if (!go) {
           // xconfirm(null, [

            var elems = [
                // Header
                "div|style=background:rgb(31, 41, 67);padding:5px;height:40px;|class=ua-card-hdr" +
                "|||span|style=color:#FFF;|class=ua-card-title|Heatmap Report Options ",

                 "br", "br",
                "div|class=cr-card cr-field" +
                "|||button|class=ugSubmitBtn|style=width:300px|onclick=PopUp('Complete Heatmap Form', null, null, true)|Edit Heatmap Form",
                // "br", "br",
                "div|class=cr-card cr-field" +
                "|||button|class=ugSubmitBtn|style=width:300px|onclick=HeatmapReport(true, 'PDF')|Download Heatmap Report (PDF)",
                // "br", "br",
                "div|class=cr-card cr-field" +
                "|||button|class=ugSubmitBtn|style=width:300px|onclick=HeatmapReport(true, 'DOCX')|Download Heatmap Report (Docx)"
            ]; 
            xconfirm(null, elems, "HeatmapReport(true,'" + pdfDoc + "')");
            document.getElementById("xconfirmCancel").className = "ugDeleteBtn";
            document.getElementById("xconfirmContinue").style.display="none";

            //removeElem("xconfirmOK");
        } else {
            try { PageContainer.removeChild(printHeatMap); } catch (ex) {
                ////c_log("printHeatMap already existed");
            }
            nsection("PageContainer", ["div|id=printHeatMap|style=display:none"]);
            xsection(printHeatMap, ["div|id=printHeatMapTopPage", "div|id=printHeatMapStatic"]);

            var data = new FormData();
            data.append("examID", MgtExamID);
            getData("GetMGTExamDoc", data, function (vr) {

                //BEGIN WRITING HEATMAP

                var js = jsHeatmapStaticPages;

                for (var i = 0; i < js.length; i++) {
                    var elems = js[i]["Elems"].split("+++");
                    var dn = (js[i]["DivName"] == null) ? "printHeatMapTopPage" : js[i]["DivName"];
                    for (var ii = 0; ii < elems.length; ii++) {
                        elems[ii] = getHeatmapElements(elems[ii]);
                    }

                    try { nsection(dn, elems); }
                    catch (ex) {
                        ////c_log(ex);
                    }
                }

                if (vr != "") {
                    vr = vr.split("<section>")[1].split("</section>")[0];
                    printHeatMapStatic.innerHTML = vr;
                }

                //BEGIN WRITING EXAM

                //set Mod Numbers
                var jsTmp = jsMgtReport;
                //////c_log(jsTmp);

                sortJS(jsTmp, "sort");
                var ModScores = [];
                //////c_log(jsTmp);

                for (var i = 0; i < jsTmp.length; i++) {
                    if (ModScores.findIndex(d => d.ModNum == jsTmp[i]["Module_Number"]) == -1) {
                        ModScores.push({ ModNum: jsTmp[i]["Module_Number"], NetScore: 0, Length: 0, Avg: 0, Clr: "" });
                    }
                }
                sortJS(ModScores, "sort");
                //////c_log(ModScores[0]);
                //////c_log(ModScores);

                //BUILD PAGE 5 TABLE FOR AVERAGES
                nsection("printHeatMap", [
                    "div|class=pageBreak xhdr|style=font-weight:bold;font-size:16px;page-break-before:always|Assessment Dashboard",
                    "table|id=tblAssessmentReportPage5|style=width:100%;border:solid 1px silver",
                    "br",
                    "div|id=divPages67"
                ]);

                //GET PAGE 5 AVERAGES AND COLORS
                var netScore = 0;
                for (var i = 0; i < ModScores.length; i++) {
                    var jsCur = jsTmp.filter(d => d.Module_Number == ModScores[i]["ModNum"]);
                    sortJS(jsCur, "NetScore", true);

                    netScore = 0;
                    for (var x = 0; x < jsCur.length; x++) {
                        if (jsCur[x].Heatmap_Statement != "")
                            netScore = netScore + jsCur[x]["NetScore"];
                    }
                    ////c_log("jscur", jsCur.filter(d => d.NetScore > 0 && d.Heatmap_Statement != ""));
                    var average = (netScore / jsCur.filter(d => d.NetScore > 0 && d.Heatmap_Statement != "").length).toFixed(2);  //only average scored questions
                    average = (isNaN(average)) ? (0).toFixed(2) : average;
                    average = average.toString().split(".")[0] * 1;

                    var clr = jsMgtScoring.filter(d => between(average, d.low, d.high))[0]["color"];
                    clr = (average == 0) ? "silver" : clr;

                    ModScores[i]["NetScore"] = netScore;
                    ModScores[i]["Length"] = jsCur.length;
                    ModScores[i]["Avg"] = average;
                    ModScores[i]["Clr"] = clr;
                }

                //////c_log("got net scores", ModScores);
                //POPULATE PAGE 5 TABLE FOR MODULES AND AVERAGES
                //sortJS(ModScores, "Avg", true);
                var bgclr = "";
                for (var i = 0; i < ModScores.length; i++) {
                    var jsCur = jsTmp.filter(d => d.Module_Number == ModScores[i]["ModNum"]);
                    ////c_log(jsCur);

                    bgclr = (bgclr == "white") ? "lightblue" : "white";
                    var clr = ModScores[i]["Clr"];
                    fclr = (clr == "green" || clr == "red") ? "white" : "black";

                    nsection("tblAssessmentReportPage5", [
                        "tr" + "|||" +
                        "td|style=background-color:" + bgclr + ";border:solid 1px silver|" + jsCur[0]["Assessment_Module"] + "|||" +
                        "td|style=background-color:" + clr + "; color:" + fclr + ";width:60px;border:solid 1px silver|" + ModScores[i]["Avg"]
                    ]);
                }

                //POPULATE PAGES 6 & 7
                sortJS(ModScores, "sort");
                ////c_log(ModScores);

                for (var i = 0; i < ModScores.length; i++) {
                    //BUILD HEATEMAP TABLE
                    var jsCur = jsTmp.filter(d => d.Module_Number == ModScores[i]["ModNum"]);
                    sortJS(jsCur, "strNetScore", true);
                    ////c_log(jsCur);


                    //BUILD PAGE 6
                    nsection("divPages67", [
                        "div|class=pageBreak xhdr|style=font-weight:bold;font-size:16px;page-break-before:always|" + jsCur[0]["Assessment_Module"] + " Residual Risk Heatmap",
                        "table|id=tblHeatmap_" + i + "|style=width:100%; border:solid 1px silver;|"
                    ]);
                    var netScore = 0;
                    for (var x = 0; x < jsCur.length; x++) {
                        var clr = jsMgtScoring.filter(d => between(jsCur[x]["NetScore"], d.low, d.high))[0]["color"];
                        //clr = (average == 0) ? "gray" : clr;
                        fclr = (clr == "red") ? "white" : (clr == "green") ? "white" : (clr == "gray") ? "white" : "black";

                        if (jsCur[x].Heatmap_Statement != "")
                            netScore = netScore + jsCur[x]["NetScore"];

                        ////c_log(jsCur[x]["Heatmap_Statement"]);

                        nsection("tblHeatmap_" + i, [
                            "tr|style=display:" + ((jsCur[x]["Heatmap_Statement"] == "") ? "none" : "") + "|||" +
                            "td|style=border:solid 1px silver| " + jsCur[x]["Heatmap_Statement"] + "|||" +
                            "td|style=border:solid 1px silver; width:60px; background-color:" + clr + "; color:" + fclr + "; text-align:center|" + jsCur[x]["NetScore"]
                        ]);
                    }

                    var average = (netScore / jsCur.filter(d => d.NetScore > 0 && d.Heatmap_Statement != "").length).toFixed(2);  //only average scored questions
                    average = (isNaN(average)) ? (0).toFixed(2) : average;
                    average = average.toString().split(".")[0] * 1;

                    var clr = jsMgtScoring.filter(d => between(average, d.low, d.high))[0]["color"];
                    clr = (average == 0) ? "gray" : clr;
                    fclr = (clr == "red") ? "white" : (clr == "green") ? "white" : (clr == "gray") ? "white" : "black";

                    nsection("tblHeatmap_" + i, [
                        "tr|||" +
                        "td|style=border:solid 1px black; background-color:gray; color:white; text-align:right; font-weight:bold|Composite Residual Risk Score|||" +
                        "td|style=border:solid 1px black; width:60px; background-color:" + clr + "; color:" + fclr + "; text-align:center; font-weight:bold|" + average
                    ]);
                    //END PAGE 6
                    ////c_log(jsCur);
                    //BUILD PAGE 7 RECOMMENDATIONS TABLE
                    try {
                        sortJS(jsCur, "Question_Number");
                        for (var x = 0; x < jsCur.length; x++) {
                            nsection("divPages67", [
                                "br",
                                "div|class=xhdr|style=font-weight:bold;font-size:16px;|Recommended Remediation: " + jsCur[0]["Assessment_Module"],
                                "table|id=divRemediations_" + i + "|style=width:100%|"
                            ]);
                            var netScore = 0;
                            var hasRems = false;
                            for (var x = 0; x < jsCur.length; x++) {
                                var rems = jsCur[x]["Recommended_Remediations"];
                                ////c_log("xxxrems", rems);

                                if (rems.length > 0) {
                                    hasRems = true;
                                    sortJS(rems, "ix");

                                    for (var xx = 0; xx < rems.length; xx++) {
                                        nsection("divRemediations_" + i, ["tr|||td|||append|li|" + rems[xx].ans]);
                                        ////c_log("xxxrems", jsCur[0]["Assessment_Module"], rems[xx])
                                    }
                                }
                            }
                            if (!hasRems) {
                                nsection("divRemediations_" + i, [
                                    "tr|||td|||append|li|No High Risk Recommended Remediation"
                                ]);
                            }
                        }
                    } catch (err) {
                        ////c_log("xxxrems", err);
                    }
                    //END PAGE 7
                }

                ////c_log(jsHeatmapStaticPages, jsMgtHeatmapForm);

                header = "";//getHeatmapElements(jsHeatmapStaticPages[0]["Header"]);
                footer = "";//getHeatmapElements(jsHeatmapStaticPages[0]["Footer"]);

                exportPDFDoc("printHeatMap", pdfDoc, header, footer, MgtXCompany + " - " + MgtExamName + " Heatmap." + pdfDoc);
                ////c_log(printHeatMap);
                PageContainer.removeChild(printHeatMap);
            });
        }
    }
}

function getHeatmapElements(str) {
    ////c_log(jsMgtHeatmapForm);

    var x = str.replace(/AGENCY/g, jsMgtHeatmapForm["Agency"])
        .replace(/ONSITEDATEFROM/g, convertDT(jsMgtHeatmapForm["OnsiteDateFrom"], true))
        .replace(/ONSITEDATETO/g, convertDT(jsMgtHeatmapForm["OnsiteDateTo"], true))
        .replace(/ONSITEADDR1/g, jsMgtHeatmapForm["OnsiteAddr1"])
        .replace(/ONSITEADDR2/g, jsMgtHeatmapForm["OnsiteAddr2"])
        .replace(/ONSITECITY/g, jsMgtHeatmapForm["OnsiteZip"])
        .replace(/ONSITESTATE/g, jsMgtHeatmapForm["OnsiteState"])
        .replace(/ONSITEZIP/g, jsMgtHeatmapForm["OnsiteZip"])
        .replace(/COMPANYPARTICIPANTS/g, jsMgtHeatmapForm["CompanyParticipants"].split("~").join("<br>"))
        .replace(/EXAMINERNAMES/g, jsMgtHeatmapForm["ExaminerNames"].split("~").join("<br>"));

    return x.replace("^^^", "");
}

function buildStaticPages(divName) {

}

function buildStaticPagesFromDoc(dv) {


}
//code: 01242025 1:00pm
var previewQuestions = [];
function showPreviewQuestions() {
    // Select all questions with the 'preview-question' class    element-449
    const previewQuestions = document.querySelectorAll('.preview-question');
    c_log('Found preview questions:', previewQuestions);

    // Make them visible by removing the 'display: none' style
    setTimeout(
        previewQuestions.forEach((question) => {
            question.style.display = ''; // Reset to default display for <tr>
            question.classList.remove('current-question'); // Remove any active highlight
            c_log(question.textContent);
        }), 1000);

    if (previewQuestions.length === 0) {
        console.warn('No preview questions found!');
    }
}


//code:so 20240705 12:11pm;
// ============================================================
// SECTION: exam/heatmap PDF and zip export (preview, naming, zip options/build, combined HTML)
// ============================================================
function PDFPreview(main) {
    var ix = main.id.split("_")[1];
    // Header styling
    document.getElementById("PopUp_" + ix + "_hdr").style.backgroundColor = "rgb(31, 41, 67)";
    document.getElementById("PopUp_" + ix + "_hdr").style.color = "white";
    document.getElementById("PopUp_" + ix + "_hdr").style.height = "50px";
    document.getElementById("PopUp_" + ix + "_hdr").style.borderRadius = "5px";
    document.getElementById("btnPopUpClose_" + ix).className = "ugCancelBtn excludePrint";
    var examVal = document.getElementById('examVal').innerText;
   // console.log(examVal);
    var assignedToVal = (document.getElementById('assignedToVal')) ? document.getElementById('assignedToVal').innerText : "";
    ////c_log(assignedToVal);

    // Get current date and time
    var currentDateTime = getCurrentDateTime();
    var currentDate = currentDateTime.date;
    var currentTime = currentDateTime.time;

    xsection(main, [
        "div|id=exportedDiv",
    ]);
    xsection(exportedDiv, [
        "div|id=printHdrDiv|style=display:flex;padding-bottom:10px;",
        "div|id=printDiv",
    ]);

    xsection(printHdrDiv, [
        "label|for=exam_Val|Exam:",
        "label|id=exam_Val|style=font-weight:bold;padding-left:5px;|" + examVal,
        "label|style=padding-left:30px;|for=assigned_To_Val|" + "        " + "Assigned to:",
        "label|id=assigned_To_Val|style=font-weight:bold;padding-left:5px;|" + assignedToVal,
        "label|style=padding-left:30px;|for=date_Val|&nbsp;&nbsp;Printed On:",
        "label|id=date_Val|style=font-weight:bold;padding-left:5px;|" + currentDate,
        "label|style=padding-left:10px;|for=time_Val|at:",
        "label|id=time_Val|style=font-weight:bold;padding-left:5px;|" + currentTime,
    ]);

    var newDiv = document.getElementById('printDiv');
    // Get the content to be cloned
    var contentDiv = document.getElementById('availExamsInner');

    // Clone the content
    var clonedContent = contentDiv.cloneNode(true);

    // Remove unwanted elements
    var textboxes = clonedContent.querySelectorAll('textarea');
    previewQuestions = clonedContent.querySelectorAll('[id^=question-]');
    const questions = clonedContent.querySelectorAll('[id^=tdQuestion_]');//code: 01242025 1:00pm
    const answers = clonedContent.querySelectorAll('[id^=tdAnswer_]');
    const otherAnswers = clonedContent.querySelectorAll('[id^=tdOtherAnswer_]');
    // previewQuestions = document.querySelectorAll('.question');
    var checkBoxes = clonedContent.querySelectorAll('input[type="checkbox"]');
    var uncheckedCheckboxes = clonedContent.querySelectorAll('input[type="checkbox"]:not(:checked)');
    var checkedCheckboxes = clonedContent.querySelectorAll('input[type="checkbox"]:checked');
    var uncheckedRadioButtons = clonedContent.querySelectorAll('input[type="radio"]:not(:checked)');
    var checkedRadioButtons = clonedContent.querySelectorAll('input[type="radio"]:checked');
    var editIcons = clonedContent.querySelectorAll('.icon');
    var resetScoringIcons = clonedContent.querySelectorAll('.resetScoring');
    var redlinkIcons = clonedContent.querySelectorAll('.redlink');
    var plusBtns = clonedContent.querySelectorAll('.plusBtn');
    var elems = clonedContent.querySelectorAll('.mgtDocSection');
    var nextprevBtns = clonedContent.querySelectorAll('button');//code: 20240729: 1100am gather all Next and Prev buttons
    var navigationButtons = clonedContent.querySelectorAll('.navigation-buttons');
    var recommendedLi = clonedContent.querySelectorAll('.recommended_li');
    // Ensure previewQuestions are styled properly code: 01242025 1:00pm
    previewQuestions.forEach(question => {
        question.style.display = ''; // Reset to default display for <tr>
        question.classList.remove('current-question'); // Remove any active highlight
        question.classList.add('preview-question');
        c_log(question);
    });
    //code: 01242025 1:00pm
    questions.forEach(question => {
        question.style.display = ''; // Reset to default display for <tr>
        question.classList.remove('current-question'); // Remove any active highlight
        question.classList.add('preview-question');
        c_log(question);
    });
    //code: 01242025 1:00pm
    answers.forEach(answer => {
        answer.style.display = ''; // Reset to default display for <tr>
        answer.classList.remove('current-question'); // Remove any active highlight
        answer.classList.add('preview-question');
        c_log(answer);
    });
    //code: 01242025 1:00pm
    otherAnswers.forEach(otherAnswer => {
        otherAnswer.style.display = ''; // Reset to default display for <tr>
        otherAnswer.classList.remove('current-question'); // Remove any active highlight
        otherAnswer.classList.add('preview-question');
        c_log(otherAnswer);
    });


    recommendedLi.forEach(function (li) {
        //let bullet = '&bull; ';  // Using HTML entity for bullet
        //li.innerHTML = bullet + " " + li.innerHTML;
        li.innerHTML = "<li>" + li.innerHTML + "</li>";//place the Recomended Remediations into a list format
    });
    textboxes.forEach(function (textbox) {
        textbox.parentNode.removeChild(textbox);
    });
    checkedCheckboxes.forEach(function (checkbox) {
        checkbox.parentNode.removeChild(checkbox);
    });
    checkedRadioButtons.forEach(function (radioButton) {
        radioButton.parentNode.removeChild(radioButton);
    });

    uncheckedCheckboxes.forEach(function (checkbox) {
        var parentDiv = checkbox.parentElement;

        // Get all child nodes of the parent div
        var childNodes = Array.prototype.slice.call(parentDiv.childNodes);

        // Iterate over the child nodes and remove the ones that are not <p> elements
        childNodes.forEach(function (node) {
            ////c_log(node.querySelectorAll('.segment'));
            if (node.nodeName !== 'P') {
                parentDiv.removeChild(node);
            }
        });
    });


    try {
        uncheckedRadioButtons.forEach(function (radioButton) {
            // Remove the parent node of each unchecked radio button

            if (radioButton.nextSibling) {
                radioButton.parentNode.removeChild(radioButton.nextSibling);
            }
            radioButton.parentNode.removeChild(radioButton);
        });

        editIcons.forEach(function (editIcon) {
            editIcon.parentNode.removeChild(editIcon);
        });
        resetScoringIcons.forEach(function (resetScoringIcon) {
            resetScoringIcon.parentNode.removeChild(resetScoringIcon);
        });
        redlinkIcons.forEach(function (redlinkIcon) {
            redlinkIcon.parentNode.removeChild(redlinkIcon);
        });
        plusBtns.forEach(function (plusBtn) {
            plusBtn.parentNode.removeChild(plusBtn);
        });

        //code: 20240729: 1100am remove the nextPrevBtns
        nextprevBtns.forEach(function (button) {
            button.parentNode.removeChild(button);
        });

        navigationButtons.forEach(function (td) {
            td.parentNode.removeChild(td);
        });
    } catch (ex) {
        ////c_log(ex);
    }

    // Assign unique IDs to the remaining elements
    var elements = clonedContent.querySelectorAll('*');
    elements.forEach(function (element, index) {
        element.id = 'element-' + index;
        element.setAttribute("name", "printElements");
    });

    // Append the modified content to the new div
    newDiv.appendChild(clonedContent);

    //removing LIs with empty text
    var lis = document.getElementsByTagName("li");
    for (var i = 0; i < lis.length; i++) {
        var lid = lis[i].id;
        if (lid.indexOf("element-") == 0 && lis[i].innerHTML == "")
            lis[i].parentElement.removeChild(lis[i]);
    }

    //loop through elements and remove the RR tags when no LIs below it
    var printElems = document.getElementsByName("printElements");
    var rr, hasLI = true;
    for (var i = 0; i < printElems.length; i++) {
        try {
            if (printElems[i].innerHTML == "Recommended Remediations") {
                if (!hasLI) {
                    rr.innerHTML = "";
                }
                rr = printElems[i];
                hasLI = false;
            }

            if (printElems[i].tagName == "LI" && printElems[i].className == "") {
                ////c_log(printElems[i], printElems[i].tagName, printElems[i].className);
                hasLI = true;
            }

        } catch (ex) {
            ////c_log(ex);
        }
    }
    //remove las RR at the end of page when no LIs below it
    if (!hasLI) {
        rr.innerHTML = "";
    }


    PopUpOpt(main, "button|id=exportButton|class=ugSubmitBtn|onclick=EnterPDFName('exportedDiv', true)|Print PDF");


}


function EnterPDFName(div, includeDocs, e) {
    if (!e) {
        xconfirm(null, [
            "div|class=smhdr|Select a filename for this pdf",
            "br",
            "label|class=sm|Enter a filename for this PDF and press [Enter]",
            "div|||input|style=width:100%|id=txtExportPDFName|onkeyup=EnterPDFName('" + div + "'," + includeDocs + ", event)|placeholder=Enter a filename and press Enter"
        ], "cancel");

    } else {
        if (e.keyCode == 13) {
            //var currentDateTime = getCurrentDateTime();
            //var currentDate = currentDateTime.date;
            //var currentTime = currentDateTime.time;

            //document.getElementById('date_Val').innerText = currentDate;
            //document.getElementById('time_Val').innerText = currentTime;



            var filename = txtExportPDFName.value;
            if (filename.trim() != "") {
                //exportHTML2PDF('exportedDiv', filename);
                var docs = (includeDocs) ? curExamDocs : [];
                //exportHTML2PDF('exportedDiv', filename); //, docs);
                //exportHTML2PDF('availExamsInner', filename); //, docs);
                exportHTML2PDF(div, filename); //, docs);
                xconfirm();
            }
            //PopUp('PDF Preview', null, null, true);
            //closePopUp();
        }
    }
}

function exportEXAM2PDF(container, filename, docs) {
    var html = document.getElementById(container).innerHTML;
    ////c_log(html);

    var data = new FormData();
    data.append("HTML", html);
    data.append("filename", filename);
    data.append("docs", ""); //docs.join(","));

    getData("storeEXAM", data, function (vr) {
        windowLoad("ExportEXAM2PDF", null, true);
    });
}

function getCurrentDateTime() {
    var now = new Date();
    var date = now.toLocaleDateString();
    var time = now.toLocaleTimeString();
    return { date: date, time: time };
}



//function ShowExamZipOptions(main, param) {
//    let ExamID = param[0];
//    let xCID = param[1];
//    xsection(main, [
//        "div|class=hdr|style=background-color:whitesmoke|Create Exam Zip File",
//        "hr", "br",
//        "div|style=padding:10px|",
//        "input|type=checkbox|id=chkIncludeHeatmap|checked=true",
//        "label|for=chkIncludeHeatmap|Include Heatmap Report",
//        "br", "br",
//        "input|type=checkbox|id=chkIncludePDF|checked=true",
//        "label|for=chkIncludePDF|Include Exam PDF",
//        "br", "br",
//        "input|type=checkbox|id=chkIncludeAttachments|checked=true",
//        "label|for=chkIncludeAttachments|Include Attachments (with Q# in filenames)",
//        "br", "br",
//        "button|class=longblueButton|style=width:300px|onclick=createExamZipFile('" + ExamID + "'," + xCID + ")|Create Zip File"
//    ]);
//}

function ShowExamZipOptions(main, param) {
    let ExamID = param[0];
    let xCID = param[1];

    var ix = main.id.split("_")[1];
    // Header styling
    document.getElementById("PopUp_" + ix + "_hdr").style.backgroundColor = "rgb(31, 41, 67)";
    document.getElementById("PopUp_" + ix + "_hdr").style.color = "white";
    document.getElementById("PopUp_" + ix + "_hdr").style.height = "50px";
    document.getElementById("PopUp_" + ix + "_hdr").style.borderRadius = "5px";
    document.getElementById("btnPopUpClose_" + ix).className = "ugCancelBtn excludePrint";

    var defaultFilename = (MgtXCompany && MgtExamName)
        ? (MgtXCompany + " - " + MgtExamName).replace(/[^a-zA-Z0-9 _\-]/g, "").trim()
        : "ExamZip";

    xsection(main, [
        "div|style=padding:16px 20px 20px 20px",
    ]);

    var container = main.querySelector("div");

    // Filename field
    xsection(container, [
        "div|id=filenameBlock|class=cr-card|style=margin-bottom:16px",
    ]);
    xsection(filenameBlock, [
        "label|style=display:block;font-weight:bold;margin-bottom:5px;font-size:13px|Zip Filename",
        "div|style=display:flex;align-items:center;gap:6px|||" +
        "input|id=txtZipFilename|style=flex:1;padding:6px 8px;border:1px solid #ccc;border-radius:4px;font-size:13px|value=" + defaultFilename +
        "|||label|style=font-size:14px;color:#888|.zip",
        "div|id=filenameError|style=color:red;font-size:12px;margin-top:4px;display:none|Please enter a filename before continuing.",
    ]);

    // Divider
    xsection(container, ["hr|style=border:none;border-top:1px solid #e0e0e0;margin:4px 0 14px 0"]);

    xsection(container, [
        "div|Id=examChkOptns|class=cr-card",
    ]);

    // Section label
    xsection(examChkOptns, [
        "div|style=font-weight:bold;font-size:13px;margin-bottom:10px|Include in zip:",
    ]);
    xsection(examChkOptns, [
        "div|style=padding:4px 10px;border-radius:10px;margin-bottom:10px;background-color:white|id=chkIncludeHeatmapDiv",
        "div|style=padding:4px 10px;border-radius:10px;margin-bottom:10px;background-color:white|id=chkIncludePDFDiv",
        "div|style=padding:4px 10px;border-radius:10px;margin-bottom:10px;background-color:white|id=chkIncludeAttachmentsDiv",
    ])

    xsection(chkIncludeHeatmapDiv, [
                 "br",
                "input|type=checkbox|id=chkIncludeHeatmap|checked=true",
                "label|style=padding-left:10px;|for=chkIncludeHeatmap|Include Heatmap Report",
                "br",
    ])

    xsection(chkIncludePDFDiv, [
       
         "br",
        "input|type=checkbox|id=chkIncludePDF|checked=true",
        "label|style=padding-left:10px;|for=chkIncludePDF|Include Exam PDF",
        "br",
    ])

    xsection(chkIncludeAttachmentsDiv, [
      
       "br",
        "input|type=checkbox|id=chkIncludeAttachments|checked=true",
        "label|style=padding-left:10px;|for=chkIncludeAttachments|Include Attachments (with Q# in filenames)",
         "br",
    ])

    // Checkbox validation message
    xsection(container, [
        "div|id=checkboxError|style=color:red;font-size:12px;margin-top:2px;display:none|Please select at least one item to include.",
    ]);

    // Submit button
    xsection(container, [
        "div|style=margin-top:18px",
    ]);
    var btnBlock = container.querySelectorAll("div");
    var lastDiv = btnBlock[btnBlock.length - 1];
    xsection(lastDiv, [
        "button|class=longblueButton|style=width:100%;padding:10px;font-size:14px|onclick=createExamZipFile('" + ExamID + "'," + xCID + ")|📦  Create Zip File",
    ]);
}


function createExamZipFile(ExamID, xCID) {
    var includeHeatmap = document.getElementById("chkIncludeHeatmap").checked;
    var includePDF = document.getElementById("chkIncludePDF").checked;
    var includeAttachments = document.getElementById("chkIncludeAttachments").checked;
    var zipFilename = document.getElementById("txtZipFilename").value.trim();

    var filenameError = document.getElementById("filenameError");
    var checkboxError = document.getElementById("checkboxError");

    // Reset errors
    filenameError.style.display = "none";
    checkboxError.style.display = "none";

    var valid = true;

    if (!zipFilename) {
        filenameError.style.display = "block";
        document.getElementById("txtZipFilename").focus();
        valid = false;
    }

    if (!includeHeatmap && !includePDF && !includeAttachments) {
        checkboxError.style.display = "block";
        valid = false;
    }

    if (!valid) return;

    closePopUp("Show Exam Zip Options");

    getExamAndHeatmapHTML(includePDF, includeHeatmap, function (examHTML, heatmapHTML) {
        var form = document.createElement("form");
        form.method = "POST";
        form.action = "CreateExamZip";
        form.style.display = "none";

        var fields = [
            { name: "examGUID", value: ExamID },
            { name: "xCID", value: xCID },
            { name: "zipFilename", value: zipFilename },
            { name: "heatmap", value: includeHeatmap.toString() },
            { name: "pdf", value: includePDF.toString() },
            { name: "attachments", value: includeAttachments.toString() },
            { name: "examHTML", value: examHTML || "" },
            { name: "heatmapHTML", value: heatmapHTML || "" }
        ];

        fields.forEach(function (f) {
            var input = document.createElement("input");
            input.type = "hidden";
            input.name = f.name;
            input.value = f.value;
            form.appendChild(input);
        });

        document.body.appendChild(form);
        form.submit();
        document.body.removeChild(form);
    });
}

//code:20261001 EXAM SNAPSHOTS - list + create (NEO_MgtGetExamSnapshots / NEO_MgtCreateExamSnapshot)
function showExamSnapshots(ExamID, xCID) {
    PopUp("Exam Snapshots", [ExamID, xCID], MgtXCompany, true, ["460px", "720px"]);
}

function ExamSnapshots(main, param) {
    let ExamID = param[0];
    let xCID = param[1];

    var ix = main.id.split("_")[1];
    document.getElementById("btnPopUpClose_" + ix).className = "ugCancelBtn excludePrint";

    xsection(main, [
        "div|style=padding:10px 16px|id=snapCreateBlock|class=cr-card",
        "div|id=snapError|style=color:red;font-size:12px;margin:6px 16px;display:none",
        "div|style=padding:10px 16px|id=snapListBlock",
    ]);

    xsection(snapCreateBlock, [
        "label|style=display:block;font-weight:bold;margin-bottom:5px;font-size:13px|New Snapshot Name (optional)",
        "div|style=display:flex;align-items:center;gap:8px|||" +
        "input|id=txtSnapshotName|maxlength=300|style=flex:1;padding:6px 8px;border:1px solid #ccc;border-radius:4px;font-size:13px|placeholder=Defaults to exam - company - date/time" +
        "|||button|id=btnCreateSnapshot|class=longblueButton|onclick=createExamSnapshot('" + ExamID + "'," + xCID + ")|Create Snapshot",
    ]);

    loadExamSnapshots(ExamID, xCID);
}

function loadExamSnapshots(ExamID, xCID) {
    getData(null, newFormData("_MgtGetExamSnapshots", { examid: ExamID, xcid: xCID }), function (vr) {
        var js = jparse(vr);
        var block = document.getElementById("snapListBlock");
        if (!block) { return; } //popup closed
        block.innerHTML = "";

        if (js.length > 0 && js[0].err) {
            showSnapshotError("Unable to load snapshots.");
            return;
        }
        js = js.filter(d => d.SnapshotID);

        if (js.length == 0) {
            xsection(block, ["div|style=color:#888;font-size:13px|No snapshots have been taken for this exam and company."]);
            return;
        }

        // rows built with DOM/textContent - snapshot names are user-entered and may contain "|" or markup
        var tbl = document.createElement("table");
        tbl.style.cssText = "width:100%;border-collapse:collapse;font-size:13px";
        var hdr = tbl.insertRow();
        ["Name", "Taken", "By", "Answers", "Docs", ""].forEach(function (h) {
            var th = document.createElement("th");
            th.textContent = h;
            th.style.cssText = "text-align:left;padding:6px;border-bottom:solid 2px #ccc";
            hdr.appendChild(th);
        });
        js.forEach(function (s) {
            var tr = tbl.insertRow();
            [s.Name, (s.DTSnapshot || "").replace("T", " ").substring(0, 16), s.CreatedByName, s.Answers, s.Docs].forEach(function (v) {
                var td = tr.insertCell();
                td.textContent = (v == null) ? "" : v;
                td.style.cssText = "padding:6px;border-bottom:solid 1px #eee";
            });

            var tdView = tr.insertCell();
            tdView.style.cssText = "padding:6px;border-bottom:solid 1px #eee;white-space:nowrap";
            if (MgtSnapshot && MgtSnapshot.SnapshotID == s.SnapshotID) {
                tdView.textContent = "Viewing";
                tdView.style.color = "#888";
            } else {
                var a = document.createElement("a");
                a.textContent = "View";
                a.className = "alink";
                a.style.cssText = "color:steelblue;cursor:pointer";
                a.onclick = function () { viewExamSnapshot(ExamID, xCID, s); };
                tdView.appendChild(a);
            }
        });
        block.appendChild(tbl);
    });
}

function createExamSnapshot(ExamID, xCID) {
    var btn = document.getElementById("btnCreateSnapshot");
    var name = document.getElementById("txtSnapshotName").value.trim();
    document.getElementById("snapError").style.display = "none";
    btn.disabled = true;

    getData(null, newFormData("_MgtCreateExamSnapshot", { examid: ExamID, xcid: xCID, name: name }), function (vr) {
        var js = jparse(vr);
        btn.disabled = false;

        if (js.length == 0 || js[0].err) {
            // proc raises "NEO_MgtCreateExamSnapshot: <reason>"; show only that part, not the server stack
            var m = (js.length > 0) ? /NEO_MgtCreateExamSnapshot: ([^\r\n]*)/.exec(js[0].err) : null;
            showSnapshotError("Snapshot was not created" + ((m) ? ": " + m[1] : "."));
            return;
        }

        document.getElementById("txtSnapshotName").value = "";
        loadExamSnapshots(ExamID, xCID);
    });
}

function showSnapshotError(msg) {
    var e = document.getElementById("snapError");
    e.textContent = msg;
    e.style.display = "block";
}

// ---- viewing an exam from a snapshot (read-only) ----
var MgtSnapshot = null; //{SnapshotID, Name, DTSnapshot, ...} while viewing a snapshot, else null

// live read proc -> snapshot read proc (004_ExamSnapshot_view_procs.sql). Same columns back, so the render code is unchanged.
var MgtSnapReads = {
    "_MgtGetExam": "_MgtSnapGetExam",
    "_MgtGetExamScoring": "_MgtSnapGetExamScoring",
    "_MgtGetHeatmapTypes": "_MgtSnapGetHeatmapTypes",
    "_MgtGetExamDocs": "_MgtSnapGetExamDocs",
    "_MgtGetAuditButtons": "_MgtSnapGetAuditButtons",
    "_MgtGetJSScoring": "_MgtSnapGetJSScoring",
    "_MgtGetForm": "_MgtSnapGetForm",
    "_MgtGetHeatmapStaticPages": "_MgtSnapGetHeatmapStaticPages",
    "_MgtGetExamAnswers": "_MgtSnapGetExamAnswers",
    "_MgtGetExamScores": "_MgtSnapGetExamScores",
    "_MgtGetHeatmap": "_MgtSnapGetHeatmap"
};

// exam writes refused by getData while a snapshot is open - they would otherwise write to the LIVE exam
var MgtSnapBlockedWrites = /^_(MgtUpdateAnswers?|MgtArchiveAnswer|MgtUpdateLMC|MgtUpdateForm|MgtDeleteFormDoc|MGTExamAttachCMSDoc|MGTExamUploadDoc|SetExamDefaultScores|MgtWorkflowRemoveAction)$/;

// [actions[], params[]] -> the snapshot equivalents when a snapshot is open.
// snapshotid goes FIRST: the adHoc dispatcher binds params positionally in key order (exec NEO_x @uid, @snapshotid, ...)
function mgtSnapMap(actions, params) {
    if (!MgtSnapshot) { return [actions, params]; }
    return [
        actions.map(a => MgtSnapReads[a] || a),
        params.map((p, i) => (MgtSnapReads[actions[i]]) ? Object.assign({ snapshotid: MgtSnapshot.SnapshotID }, p) : p)
    ];
}

function setMgtSnapshot(snapshot) {
    MgtSnapshot = snapshot || null;
    getDataGuard = (MgtSnapshot) ? function (action) {
        if ((action || "").split(",").some(a => MgtSnapBlockedWrites.test(a))) {
            xconfirm("You are viewing a read-only snapshot. Return to the live exam to make changes.");
            return false;
        }
        return true;
    } : null;

    if (MgtSnapshot && !document.getElementById("mgtSnapROStyle")) {
        var st = document.createElement("style");
        st.id = "mgtSnapROStyle";
        st.textContent =
            "#availExamsInner.mgtSnapRO textarea, #availExamsInner.mgtSnapRO input, #availExamsInner.mgtSnapRO select," +
            "#availExamsInner.mgtSnapRO [onclick*='MgtEditAnswer'], #availExamsInner.mgtSnapRO [onclick*='MGTUpload']," +
            "#availExamsInner.mgtSnapRO [onclick*='MGTSetDefaultScores'] { pointer-events:none; }" +
            "#availExamsInner.mgtSnapRO textarea, #availExamsInner.mgtSnapRO input { background-color:#f6f6f6; }";
        document.head.appendChild(st);
    }
}

function viewExamSnapshot(ExamID, xCID, snapshot) {
    closePopUp("Exam Snapshots");
    viewMgtExam(ExamID, xCID, MgtXCompany, snapshot);
}

function buildSnapshotBanner(ExamID, xcid, xcompany) {
    var b = document.createElement("div");
    b.id = "snapBanner";
    b.className = "excludePrint";
    b.style.cssText = "margin-top:8px;padding:6px 12px;background-color:#fff4d6;border:solid 1px #e0b84c;border-radius:4px;font-size:13px";

    var t = document.createElement("span");
    t.style.fontWeight = "bold";
    t.textContent = "Read-only snapshot: " + MgtSnapshot.Name + " (taken " + (MgtSnapshot.DTSnapshot || "").replace("T", " ").substring(0, 16) + ")";
    b.appendChild(t);

    var a = document.createElement("a");
    a.textContent = "Return to live exam";
    a.style.cssText = "color:steelblue;cursor:pointer;margin-left:20px";
    a.onclick = function () { viewMgtExam(ExamID, xcid, xcompany); };
    b.appendChild(a);

    document.getElementById("ExamHeader").appendChild(b);
}

// Helper to build HTMLs asynchronously (for exam PDF and heatmap)
function getExamAndHeatmapHTML(includePDF, includeHeatmap, callback) {
    var examHTML = "";
    var heatmapHTML = "";

    console.log("Starting getExamAndHeatmapHTML: includePDF=", includePDF, "includeHeatmap=", includeHeatmap);

    // Exam PDF generation
    if (includePDF) {
        var tempDiv = document.createElement("div");
        tempDiv.id = "tempPDFPreview";
        tempDiv.style.display = "none";
        document.body.appendChild(tempDiv);

        try {
            PDFPreview(tempDiv);
            var exportedDiv = document.getElementById("exportedDiv");
            if (exportedDiv) {
                examHTML = exportedDiv.innerHTML;
                console.log("Exam HTML generated, length:", examHTML.length);
            } else {
                console.error("exportedDiv not found after PDFPreview");
            }
        } catch (ex) {
            console.error("Error generating exam HTML:", ex);
        }
        // Clean up temp div
        if (tempDiv.parentNode) {
            tempDiv.parentNode.removeChild(tempDiv);
        }
    }

    // Heatmap generation
    if (includeHeatmap) {
        if (!jsMgtHeatmapForm || !jsMgtHeatmapForm["FormCompleted"]) {
            console.error("Heatmap form not completed - cannot generate report");
            callback(examHTML, "");
            return;
        }

        console.log("Heatmap form completed - overriding exportPDFDoc");

        var originalExportPDFDoc = window.exportPDFDoc;
        window.exportPDFDoc = function (divName, pdfDoc, header, footer, filename) {
            // Capture synchronously — right now, before HeatmapReport calls removeChild
            var heatMapElement = document.getElementById(divName);
            heatmapHTML = (heatMapElement && heatMapElement.innerHTML.trim() !== "")
                ? heatMapElement.innerHTML
                : "";

            console.log("Heatmap HTML captured, length:", heatmapHTML.length);

            // Restore before callback in case callback triggers another exportPDFDoc
            window.exportPDFDoc = originalExportPDFDoc;

            // Still defer the callback so we're not mid-stack inside HeatmapReport
            setTimeout(() => {
                callback(examHTML, heatmapHTML);
            }, 0);
        };

        try {
            console.log("Calling HeatmapReport(true, null)");
            //HeatmapReport(true, null);
            //return; // async, wait for exportPDFDoc interception
            generateJSReport(function (success) {
                if (!success) {
                    console.warn("Heatmap data not available — skipping heatmap in zip.");
                    window.exportPDFDoc = originalExportPDFDoc;
                    callback(examHTML, "");
                    return;
                }
                try {
                    HeatmapReport(true, null);
                } catch (ex) {
                    console.error("Error starting HeatmapReport:", ex);
                    window.exportPDFDoc = originalExportPDFDoc;
                    callback(examHTML, "");
                }
            });
            return;
        } catch (ex) {
            console.error("Error starting HeatmapReport:", ex);
            window.exportPDFDoc = originalExportPDFDoc;
            callback(examHTML, "");
        }
    } else {
        // No heatmap requested
        console.log("Final (no heatmap): examHTML length=", examHTML.length, "heatmapHTML length=", heatmapHTML.length);
        callback(examHTML, heatmapHTML);
    }
}

//code:20261026 EXAM "ACTIONS" DROPDOWN - the right-hand exam options in one select (built in viewMgtExam).
// Each entry is a label + function; entries can arrive late (Workflow waits on the server) and are kept unique by label.
var MgtExamActions = [];

function buildExamActions() {
    MgtExamActions = [];
    var wrap = document.getElementById("examActionsWrap");
    if (!wrap) { return; }
    wrap.innerHTML = "";

    var sel = document.createElement("select");
    sel.id = "examActions";
    sel.style.cssText = "padding:5px;font-weight:bold;color:maroon;cursor:pointer";
    var ph = document.createElement("option");
    ph.value = "";
    ph.textContent = "Actions";
    sel.appendChild(ph);
    sel.onchange = function () {
        var a = MgtExamActions[sel.value];
        sel.value = "";
        if (a) { a.fn(); }
    };
    wrap.appendChild(sel);
}

function addExamAction(label, fn) {
    var sel = document.getElementById("examActions");
    if (!sel || MgtExamActions.some(a => a.label == label)) { return; }
    MgtExamActions.push({ label: label, fn: fn });
    var opt = document.createElement("option");
    opt.value = MgtExamActions.length - 1;
    opt.textContent = label;
    sel.appendChild(opt);
}

//code:20261025 EXAM WORKFLOW - remediation tracking (SharedSQLWithClaude/FEATURE_ExamWorkflow, spec markdowns/CMSNeo_Workflow_Spec.md)
// The exam write procs log to the workflow themselves (003_ExamWorkflow_hooks.sql); this page only reads it,
// shows the link, asks the one-hour question, and makes the PDF report. Every call is re-checked server-side
// (CID 1518 network + AccessTreeDown / own company).
var MgtWorkflowSendUrl = "../main/SendWorkflowPdf"; // CMSMailbox's exam viewer overrides these two
var MgtWorkflowPdfUrl = "../main/WorkflowPdf";
var MgtWorkflowCanManage = false;

var MgtWorkflowEventNames = {
    remediation_set: "Remediation set",
    remediation_edited: "Remediation edited",
    remediation_removed: "Remediation removed (complete)",
    action_removed: "Removed from workflow",
    answer_added: "Answer added",
    answer_edited: "Answer edited",
    answer_archived: "Answer archived",
    doc_uploaded: "Document uploaded",
    doc_attached: "Document attached",
    doc_deleted: "Document deleted"
};

function mgtWorkflowDT(dt) {
    return (dt == null || dt == "") ? "time not recorded" : convertDT(dt);
}

// "Workflow" entry in the exam's Actions dropdown. The status call also back-fills an exam begun before this feature.
function loadWorkflowLink(ExamID, xcid) {
    getData(null, newFormData("_MgtGetWorkflowStatus", { examid: ExamID, xcid: xcid }), function (vr) {
        var js = jparse(vr);
        if (js.length == 0 || js[0].err || !js[0].HasWorkflow) { return; }
        MgtWorkflowCanManage = js[0].CanManage;
        addExamAction("Workflow", function () { showExamWorkflow(ExamID, xcid); });
    });
}

// The workflow report opens in its own browser tab (John, 2026-10-26). The tab is a blank same-origin page that
// this exam page writes into and keeps driving: every server call still goes through this page's getData/fetch
// with its live token, so the tab needs no login or token of its own. wfDoc is the tab's document.
var wfWin = null;
var wfDoc = document;

function showExamWorkflow(ExamID, xCID) {
    var w = window.open("", "cmsExamWorkflow_" + ExamID + "_" + xCID);
    if (!w) {
        xconfirm("Your browser blocked the Workflow tab. Allow pop-ups for this site, then choose Workflow again.");
        return;
    }
    // only one tab is driven at a time: an earlier tab for another exam is told it's disconnected
    if (wfWin && wfWin !== w && !wfWin.closed) { mgtWorkflowDetach(wfWin.document); }
    if (!MgtWorkflowUnloadHooked) {
        MgtWorkflowUnloadHooked = true;
        window.addEventListener("pagehide", function () {
            try { if (wfWin && !wfWin.closed) { mgtWorkflowDetach(wfWin.document); } } catch (ex) { }
        });
    }
    wfWin = w;
    wfDoc = w.document;

    var exam = (jsMgtExam && jsMgtExam[0]) ? jsMgtExam[0] : {};
    wfDoc.open();
    wfDoc.write("<!doctype html><html><head><meta charset='utf-8'><title>Workflow</title><style>" +
        "html,body{height:100%;margin:0}" +
        "body{font-family:Arial,Helvetica,sans-serif;font-size:13px;color:#222;display:flex;flex-direction:column;background:#fff}" +
        "#wfHead{padding:12px 16px 4px 16px;flex:none;border-bottom:solid 1px #ddd}" +
        "#wfHead .t{font-size:18px;font-weight:bold;margin-bottom:4px}" +
        "#wfHead span{margin-right:36px}" +
        ".longblueButton{background-color:steelblue;color:#fff;border:none;border-radius:4px;padding:6px 12px;font-size:13px;cursor:pointer}" +
        ".longblueButton:disabled{opacity:.6;cursor:default}" +
        "</style></head><body>" +
        "<div id='wfHead'><div class='t'>Exam Workflow</div><div id='wfHeadInfo'></div></div>" +
        "<div id='wfToolbar' style='padding:8px 16px;flex:none'></div>" +
        "<div id='wfSend' style='padding:6px 16px;display:none;flex:none'></div>" +
        "<div id='wfError' style='color:red;font-size:12px;margin:6px 16px;display:none;flex:none'></div>" +
        "<div id='wfMsg' style='color:#1d6b33;font-size:12px;margin:6px 16px;display:none;flex:none'></div>" +
        "<div id='wfSummary' style='padding:2px 16px 6px 16px;color:#555;flex:none'></div>" +
        "<div id='wfList' style='padding:6px 16px 16px 16px;flex:1;min-height:0;overflow-y:auto'></div>" +
        "</body></html>");
    wfDoc.close();
    wfDoc.title = "Workflow - " + (MgtExamName || "Exam") + " - " + (MgtXCompany || "");

    // header: Exam / Managed By / Assigned to, as on the PDF (textContent: names are user-entered)
    var info = wfDoc.getElementById("wfHeadInfo");
    [["Exam: ", MgtExamName], ["Managed By: ", exam.ManagingCompany], ["Assigned to: ", MgtXCompany]].forEach(function (p) {
        var sp = wfDoc.createElement("span");
        sp.appendChild(wfDoc.createTextNode(p[0]));
        var b = wfDoc.createElement("b");
        b.textContent = p[1] || "";
        sp.appendChild(b);
        info.appendChild(sp);
    });

    MgtWorkflowOpen = []; // a freshly opened tab starts with every action's details hidden
    ExamWorkflow(ExamID, xCID);
    w.focus();
}

var MgtWorkflowUnloadHooked = false;

// the exam page that drives this tab is gone (or now drives another tab): say so and disable the controls
function mgtWorkflowDetach(doc) {
    try {
        Array.from(doc.querySelectorAll("button,select,textarea,input")).forEach(e => e.disabled = true);
        if (doc.getElementById("wfDetached")) { return; }
        var d = doc.createElement("div");
        d.id = "wfDetached";
        d.style.cssText = "margin:8px 16px;padding:6px 12px;background-color:#fff4d6;border:solid 1px #e0b84c;border-radius:4px;flex:none";
        d.textContent = "This Workflow tab is no longer connected to its exam. Reopen it from the exam's Actions menu to refresh or send it.";
        var head = doc.getElementById("wfHead");
        if (head) { head.parentNode.insertBefore(d, head.nextSibling); }
    } catch (ex) { }
}

function ExamWorkflow(ExamID, xCID) {
    var bar = wfDoc.getElementById("wfToolbar");
    bar.style.cssText += ";display:flex;align-items:center;gap:12px";

    var fl = wfDoc.createElement("label");
    fl.style.fontSize = "13px";
    fl.textContent = "Show: ";
    var sel = wfDoc.createElement("select");
    sel.id = "wfFilter";
    sel.style.cssText = "padding:4px;font-size:13px";
    [["all", "Everything"], ["pending", "Pending only"]].forEach(function (o) {
        var opt = wfDoc.createElement("option");
        opt.value = o[0];
        opt.textContent = o[1];
        sel.appendChild(opt);
    });
    try { sel.value = localStorage.getItem("mgtWorkflowFilter") || "all"; } catch (ex) { }
    sel.onchange = function () {
        try { localStorage.setItem("mgtWorkflowFilter", sel.value); } catch (ex) { }
        renderExamWorkflow();
    };
    fl.appendChild(sel);
    bar.appendChild(fl);

    // the PDF is the displayed report: same rows, same Show filter (built server-side, landscape)
    var dl = wfDoc.createElement("button");
    dl.className = "longblueButton";
    dl.textContent = "Download PDF";
    dl.onclick = function () { mgtWorkflowDownloadPdf(ExamID, xCID, dl); };
    bar.appendChild(dl);

    var btn = wfDoc.createElement("button");
    btn.className = "longblueButton";
    btn.textContent = "Send PDF via Secure Email";
    btn.onclick = function () { mgtWorkflowShowSend(ExamID, xCID); };
    bar.appendChild(btn);

    // the tab doesn't see later changes made on the exam page by itself
    var rf = wfDoc.createElement("button");
    rf.className = "longblueButton";
    rf.textContent = "Refresh";
    rf.onclick = function () { loadExamWorkflow(ExamID, xCID); };
    bar.appendChild(rf);

    loadExamWorkflow(ExamID, xCID);
}

var MgtWorkflowRows = []; // last _MgtGetWorkflowLines result; the Show filter re-renders from it
var MgtWorkflowOpen = []; // LineIDs whose details are expanded (kept across filter changes and Refresh)

function loadExamWorkflow(ExamID, xCID) {
    getData(null, newFormData("_MgtGetWorkflowLines", { examid: ExamID, xcid: xCID }), function (vr) {
        var js = jparse(vr);
        if (!wfWin || wfWin.closed) { return; } //tab closed
        var block = wfDoc.getElementById("wfList");
        if (!block) { return; }
        block.innerHTML = "";
        mgtWorkflowError("");

        if (js.length > 0 && js[0].err) {
            mgtWorkflowError("Unable to load the workflow.");
            return;
        }
        MgtWorkflowRows = js.filter(d => d.LineID);
        renderExamWorkflow();
    });
}

// _MgtGetWorkflowLines rows (in exam order) -> one entry per question, with its remediations (in the
// order they were set) and the combined timeline. Shared by the tab; the PDF groups the same way server-side.
function mgtWorkflowGroupByLine(js) {
    var lines = [];
    js.forEach(function (r) {
        var ln = lines.find(l => l.LineID == r.LineID);
        if (!ln) {
            ln = { LineID: r.LineID, Module: r.Module, ModNum: r.ModNum, QuestNum: r.QuestNum, Question: r.Question, rems: [], events: [] };
            lines.push(ln);
        }
        ln.events.push(r);
        if (r.ActionID && !ln.rems.find(a => a.ActionID == r.ActionID)) {
            ln.rems.push({ ActionID: r.ActionID, RemediationText: r.RemediationText, Status: r.Status, DTSet: r.DTSet,
                SetByName: r.SetByName, DTCompleted: r.DTCompleted, CompletedByName: r.CompletedByName, CompletedTimeKnown: r.CompletedTimeKnown });
        }
    });
    lines.forEach(function (ln) {
        ln.rems.sort((a, b) => (a.DTSet < b.DTSet) ? -1 : (a.DTSet > b.DTSet) ? 1 : a.ActionID - b.ActionID);
        ln.pending = ln.rems.filter(a => a.Status == "Pending").length;
    });
    return lines;
}

function renderExamWorkflow() {
    var block = wfDoc.getElementById("wfList");
    if (!block) { return; }
    block.innerHTML = "";
    var sum = wfDoc.getElementById("wfSummary");
    sum.textContent = "";

    var lines = mgtWorkflowGroupByLine(MgtWorkflowRows);
    if (lines.length == 0) {
        mgtWorkflowNote(block, "No workflow actions for this exam and company.");
        return;
    }

    // status is by question: Pending until every remediation set on it has been removed (John, 2026-10-27)
    var remCount = lines.reduce((n, l) => n + l.rems.length, 0);
    var linesPending = lines.filter(l => l.pending > 0).length;
    sum.textContent = lines.length + " question(s): " + linesPending + " pending, " + (lines.length - linesPending) + " complete" +
        "  ·  " + remCount + " remediation(s)";

    var filter = wfDoc.getElementById("wfFilter");
    if (filter && filter.value == "pending") {
        lines = lines.filter(l => l.pending > 0);
        if (lines.length == 0) {
            mgtWorkflowNote(block, "No pending actions.");
            return;
        }
    }

    // one card per question (exam order); DOM/textContent because answers and remediation text are user-entered
    lines.forEach(function (ln) {
        var id = ln.LineID;
        var card = wfDoc.createElement("div");
        card.style.cssText = "border:solid 1px #ddd;border-radius:4px;margin-bottom:10px;padding:8px 10px;font-size:13px";

        var hd = wfDoc.createElement("div");
        hd.style.cssText = "display:flex;justify-content:space-between;gap:10px";
        var ttl = wfDoc.createElement("div");
        ttl.style.fontWeight = "bold";
        ttl.textContent = (ln.ModNum || "") + "." + (ln.QuestNum || "") + " " + (ln.Module || "");
        hd.appendChild(ttl);
        hd.appendChild(mgtWorkflowBadge((ln.pending > 0) ? "Pending" : "Complete"));
        card.appendChild(hd);

        if (ln.Question) {
            var q = wfDoc.createElement("div");
            q.style.cssText = "color:#555;margin:3px 0";
            q.textContent = ln.Question;
            card.appendChild(q);
        }

        // each distinct remediation on the question once, with when it was set / removed (the status is the
        // question's, above). One set and removed several times is one row; every cycle is in the timeline.
        var groups = mgtWorkflowRemGroups(ln.rems);
        var lbl = wfDoc.createElement("div");
        lbl.style.cssText = "margin:6px 0 2px 0;font-weight:bold";
        lbl.textContent = (groups.length == 1) ? "Remediation:" : "Remediations (" + groups.length + "):";
        card.appendChild(lbl);
        var list = wfDoc.createElement("table");
        list.style.cssText = "width:100%;border-collapse:collapse";
        mgtWorkflowFixedCols(list, MgtWorkflowRemCols);
        groups.forEach(function (g) {
            var tr = list.insertRow();
            var tdTxt = tr.insertCell();
            tdTxt.textContent = g.text;
            tdTxt.style.cssText = "padding:2px 6px 2px 12px;vertical-align:top";
            var tdWhen = tr.insertCell();
            tdWhen.textContent = mgtWorkflowRemHistory(g.rems);
            tdWhen.style.cssText = "padding:2px 6px;color:#555;vertical-align:top;font-size:12px";
        });
        card.appendChild(list);

        // the combined timeline is hidden until the "Show details" line is clicked (arrow on the far right)
        var open = MgtWorkflowOpen.indexOf(id) > -1;
        var tog = wfDoc.createElement("div");
        tog.style.cssText = "display:flex;justify-content:space-between;align-items:center;margin-top:6px;padding:4px 6px;" +
            "border-top:solid 1px #eee;color:steelblue;cursor:pointer;user-select:none";
        var togTxt = wfDoc.createElement("span");
        var togArrow = wfDoc.createElement("span");
        togArrow.style.cssText = "font-size:12px;padding-left:10px";
        tog.appendChild(togTxt);
        tog.appendChild(togArrow);
        card.appendChild(tog);

        var tbl = wfDoc.createElement("table");
        tbl.style.cssText = "width:100%;border-collapse:collapse;margin-top:2px";
        mgtWorkflowFixedCols(tbl, MgtWorkflowEventCols);

        function setOpen(o) {
            open = o;
            tbl.style.display = (open) ? "" : "none";
            togTxt.textContent = ((open) ? "Hide details" : "Show details") + " (" + ln.events.length + ")";
            togArrow.textContent = (open) ? "▲" : "▼";
            MgtWorkflowOpen = MgtWorkflowOpen.filter(x => x != id);
            if (open) { MgtWorkflowOpen.push(id); }
        }
        tog.onclick = function () { setOpen(!open); };
        setOpen(open);

        ln.events.forEach(function (e) {
            var tr = tbl.insertRow();
            var by = (e.ActorName || "") + ((e.ActorCompany) ? " (" + e.ActorCompany + ")" : "");
            [mgtWorkflowDT(e.DTEvent), MgtWorkflowEventNames[e.EventType] || e.EventType, by, mgtWorkflowDetail(e)].forEach(function (v, i) {
                var td = tr.insertCell();
                td.textContent = v;
                td.style.cssText = "padding:3px 6px;border-top:solid 1px #eee;vertical-align:top" +
                    ((i == 3) ? ";color:#555" : "");
            });
        });
        card.appendChild(tbl);
        block.appendChild(card);
    });
}

// Every question's tables use the same fixed column widths, so the columns line up from one section to
// the next (auto layout sized each table to its own content). The remediation list's "Set ... removed ..."
// column starts where the timeline's Detail column does. The PDF uses the same widths.
var MgtWorkflowEventCols = ["12%", "18%", "25%", "45%"]; // When, Event, By, Detail
var MgtWorkflowRemCols = ["55%", "45%"];                 // remediation, set/removed history

function mgtWorkflowFixedCols(table, widths) {
    table.style.tableLayout = "fixed";
    table.style.wordWrap = "break-word";
    var cg = wfDoc.createElement("colgroup");
    widths.forEach(function (w) {
        var c = wfDoc.createElement("col");
        c.style.width = w;
        cg.appendChild(c);
    });
    table.insertBefore(cg, table.firstChild);
}

// a question's remediations (sorted by DTSet) grouped by their text, in the order each was first set
function mgtWorkflowRemGroups(rems) {
    var groups = [];
    rems.forEach(function (a) {
        var key = (a.RemediationText || "").trim().toLowerCase();
        var g = groups.find(x => x.key == key);
        if (!g) { g = { key: key, text: a.RemediationText || "", rems: [] }; groups.push(g); }
        g.rems.push(a);
    });
    return groups;
}

// "Set ... by ...; removed ... by ..." for one remediation; for one set more than once:
// "Set 5 times, first ..., last ... by ...; last removed ... by ..." (or "; still set")
// (the PDF builder mirrors this)
function mgtWorkflowRemHistory(rems) {
    var last = rems[rems.length - 1];
    var removed = (last.Status == "Complete")
        ? "removed " + ((last.CompletedTimeKnown) ? mgtWorkflowDT(last.DTCompleted) : "(time not recorded)") +
          ((last.CompletedByName) ? " by " + last.CompletedByName : "")
        : "";
    if (rems.length == 1) {
        return "Set " + mgtWorkflowDT(last.DTSet) + ((last.SetByName) ? " by " + last.SetByName : "") + ((removed) ? "; " + removed : "");
    }
    return "Set " + rems.length + " times, first " + mgtWorkflowDT(rems[0].DTSet) + ", last " + mgtWorkflowDT(last.DTSet) +
        ((last.SetByName) ? " by " + last.SetByName : "") + ((removed) ? "; last " + removed : "; still set");
}

// what an event row says in the Detail column (the PDF builder mirrors this)
function mgtWorkflowDetail(e) {
    var detail = (e.NewText || e.OldText || "");
    if (e.EventType == "answer_edited" && e.OldText) { detail = e.OldText + "  →  " + (e.NewText || ""); }
    // with several remediations on one question, the remediation rows name which one
    if (e.EventType == "remediation_set" || e.EventType == "remediation_removed") { detail = e.RemediationText || ""; }
    if (e.Note) { detail = (detail ? detail + " " : "") + "[" + e.Note + "]"; }
    return detail;
}

function mgtWorkflowBadge(status, text) {
    var b = wfDoc.createElement("span");
    b.textContent = text || status;
    b.style.cssText = "padding:1px 8px;border-radius:10px;font-size:12px;white-space:nowrap;" +
        ((status == "Pending") ? "background-color:#fff4d6;color:#8a6100" : "background-color:#dff3e3;color:#1d6b33");
    return b;
}

function mgtWorkflowError(msg) {
    var e = wfDoc.getElementById("wfError");
    if (!e) { return; }
    e.textContent = msg;
    e.style.display = (msg) ? "block" : "none";
    if (msg) { mgtWorkflowMsg(""); }
}

// confirmation line in the tab (the exam page's smconfirm would show on the other tab)
function mgtWorkflowMsg(msg) {
    var e = wfDoc.getElementById("wfMsg");
    if (!e) { return; }
    e.textContent = msg;
    e.style.display = (msg) ? "block" : "none";
    if (msg) { setTimeout(function () { if (e.textContent == msg) { e.style.display = "none"; } }, 4000); }
}

function mgtWorkflowNote(block, msg) {
    var d = wfDoc.createElement("div");
    d.style.cssText = "color:#888;font-size:13px";
    d.textContent = msg;
    block.appendChild(d);
}

// ---- one-hour rule: after unchecking a remediation, offer to drop the matching workflow action ----
function mgtWorkflowCheckRemoval(LineID, QNum) {
    getData(null, newFormData("_MgtGetWorkflowRecentRemoval", { examid: MgtExamID, xcid: MgtXCID, lineid: LineID, qnum: QNum }), function (vr) {
        var js = jparse(vr);
        if (js.length == 0 || js[0].err || !js[0].ActionID) { return; }

        xconfirm("This remediation was added less than an hour ago. Remove the corresponding action from the Workflow?",
            null, "mgtWorkflowRemoveAction(" + (js[0].ActionID * 1) + ")");
        // "No" (or closing) keeps the action, already marked complete
        try {
            xconfirmCancel.innerHTML = "No, keep it";
            xconfirmContinue.innerHTML = "Yes, remove";
        } catch (ex) { }
    });
}

function mgtWorkflowRemoveAction(actionID) {
    xconfirm();
    getData(null, newFormData("_MgtWorkflowRemoveAction", { actionid: actionID }), function (vr) {
        var js = jparse(vr);
        if (js.length == 0 || js[0].status != "ok") {
            xconfirm("The workflow action could not be removed" + ((js.length > 0 && js[0].status == "not_allowed") ? " (more than an hour old, or not permitted)." : "."));
        }
    });
}

function mgtWorkflowPendingOnly() {
    var f = wfDoc.getElementById("wfFilter");
    return !!(f && f.value == "pending");
}

// ---- PDF report: download (MailboxShareController.WorkflowPdf) ----
function mgtWorkflowDownloadPdf(ExamID, xCID, btn) {
    mgtWorkflowError("");
    btn.disabled = true;
    var fd = new FormData();
    fd.append("strjson", JSON.stringify({ examId: ExamID, xcid: xCID, pendingOnly: mgtWorkflowPendingOnly() }));
    fetch(MgtWorkflowPdfUrl, { method: "POST", headers: { "Authorization": "Bearer " + UserToken }, body: fd })
        .then(function (r) {
            if (!r.ok) throw new Error("WorkflowPdf " + r.status);
            var cd = r.headers.get("Content-Disposition") || "";
            var m = /filename\*=UTF-8''([^;]+)/i.exec(cd) || /filename="?([^";]+)"?/i.exec(cd);
            return r.blob().then(function (b) { return { blob: b, name: (m) ? decodeURIComponent(m[1]) : "Workflow.pdf" }; });
        })
        .then(function (f) {
            btn.disabled = false;
            var url = URL.createObjectURL(f.blob);
            var a = wfDoc.createElement("a");
            a.href = url;
            a.download = f.name;
            wfDoc.body.appendChild(a);
            a.click();
            wfDoc.body.removeChild(a);
            setTimeout(function () { URL.revokeObjectURL(url); }, 10000);
        })
        .catch(function (ex) {
            btn.disabled = false;
            mgtWorkflowError("The PDF could not be created - see console.");
            console.log("WorkflowPdf failed", ex);
        });
}

// ---- PDF report via secure email (MailboxShareController.SendWorkflowPdf -> CMSMailbox message + attachment) ----
function mgtWorkflowShowSend(ExamID, xCID) {
    var box = wfDoc.getElementById("wfSend");
    mgtWorkflowError("");
    box.style.display = "";
    box.innerHTML = "<div style='color:#777;font-size:13px'>Loading recipients...</div>";

    getData(null, newFormData("_MgtGetWorkflowRecipients", { examid: ExamID, xcid: xCID }), function (vr) {
        var js = jparse(vr);
        box.innerHTML = "";
        if (js.length > 0 && js[0].err) { mgtWorkflowError("Unable to load recipients."); return; }
        js = js.filter(d => d.UID);

        var lbl = wfDoc.createElement("div");
        lbl.style.cssText = "font-weight:bold;font-size:13px;margin-bottom:4px";
        lbl.textContent = "Send the Workflow PDF (" + (mgtWorkflowPendingOnly() ? "pending only" : "everything") + ") to:";
        box.appendChild(lbl);

        if (js.length == 0) {
            var none = wfDoc.createElement("div");
            none.style.cssText = "color:#888;font-size:13px";
            none.textContent = "No one who works this exam can receive secure email.";
            box.appendChild(none);
            return;
        }

        var list = wfDoc.createElement("div");
        list.style.cssText = "max-height:160px;overflow-y:auto;font-size:13px;border:solid 1px #eee;padding:4px";
        js.forEach(function (r) {
            var row = wfDoc.createElement("label");
            row.style.cssText = "display:block;padding:2px 0;cursor:pointer";
            var cb = wfDoc.createElement("input");
            cb.type = "checkbox";
            cb.value = r.UID;
            cb.className = "wfRecipient";
            row.appendChild(cb);
            row.appendChild(wfDoc.createTextNode(" " + r.Name + " (" + (r.Company || "") + ")" + ((r.Side == "target") ? "" : " - management")));
            list.appendChild(row);
        });
        box.appendChild(list);

        var note = wfDoc.createElement("textarea");
        note.id = "wfSendNote";
        note.placeholder = "Message (optional)";
        note.style.cssText = "width:100%;height:50px;margin-top:6px;font-size:13px";
        box.appendChild(note);

        var send = wfDoc.createElement("button");
        send.className = "longblueButton";
        send.textContent = "Send";
        send.onclick = function () { mgtWorkflowSend(ExamID, xCID, send); };
        box.appendChild(send);
    });
}

function mgtWorkflowSend(ExamID, xCID, btn) {
    var uids = Array.from(wfDoc.getElementsByClassName("wfRecipient")).filter(c => c.checked).map(c => c.value * 1);
    if (uids.length == 0) { mgtWorkflowError("Pick at least one recipient."); return; }
    mgtWorkflowError("");
    btn.disabled = true;

    var fd = new FormData();
    fd.append("strjson", JSON.stringify({ examId: ExamID, xcid: xCID, recipients: uids, body: wfDoc.getElementById("wfSendNote").value, pendingOnly: mgtWorkflowPendingOnly() }));
    fetch(MgtWorkflowSendUrl, { method: "POST", headers: { "Authorization": "Bearer " + UserToken }, body: fd })
        .then(function (r) { return r.text(); })
        .then(function (vr) {
            btn.disabled = false;
            var res = jparse(vr);
            if (res.status == "ok") {
                wfDoc.getElementById("wfSend").style.display = "none";
                mgtWorkflowMsg("Workflow PDF sent by secure email.");
            } else {
                mgtWorkflowError("The PDF was not sent (" + (res.status || "error") + ").");
            }
        })
        .catch(function (ex) {
            btn.disabled = false;
            mgtWorkflowError("The PDF was not sent - see console.");
            console.log("SendWorkflowPdf failed", ex);
        });
}
