package main

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

const filesListenAddr = "127.0.0.1:58633"

var filesRoot = os.Getenv("USERPROFILE")

func errorBody(code string) map[string]any {
	return map[string]any{"ok": false, "code": code}
}

// resolveFilePath confines rel to filesRoot, rejecting traversal and symlink escapes.
func resolveFilePath(rel string) (string, error) {
	clean := filepath.Clean(string(filepath.Separator) + rel)
	full := filepath.Join(filesRoot, clean)
	resolved, err := filepath.EvalSymlinks(full)
	if err != nil {
		return "", errors.New("path not found")
	}
	rootResolved, err := filepath.EvalSymlinks(filesRoot)
	if err != nil {
		return "", errors.New("root not found")
	}
	if !strings.EqualFold(resolved, rootResolved) &&
		!strings.HasPrefix(strings.ToLower(resolved), strings.ToLower(rootResolved)+string(os.PathSeparator)) {
		return "", errors.New("path outside root")
	}
	return resolved, nil
}

func relativeToRoot(full string) string {
	rel, err := filepath.Rel(filesRoot, full)
	if err != nil {
		return "/"
	}
	if rel == "." {
		return "/"
	}
	return "/" + filepath.ToSlash(rel)
}

type fileEntry struct {
	Name     string `json:"name"`
	Dir      bool   `json:"dir"`
	Size     int64  `json:"size"`
	Modified string `json:"modified"`
}

func writeFilesJSON(writer http.ResponseWriter, status int, value any) {
	body, err := json.Marshal(value)
	if err != nil {
		status = http.StatusInternalServerError
		body = []byte(`{"ok":false,"code":"internal_error"}`)
	}
	writer.Header().Set("Content-Type", "application/json; charset=utf-8")
	writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(status)
	_, _ = writer.Write(body)
}

func filesListHandler(writer http.ResponseWriter, request *http.Request) {
	full, err := resolveFilePath(request.URL.Query().Get("path"))
	if err != nil {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("invalid_path"))
		return
	}
	infos, err := os.ReadDir(full)
	if err != nil {
		writeFilesJSON(writer, http.StatusNotFound, errorBody("path_not_found"))
		return
	}
	entries := make([]fileEntry, 0, len(infos))
	for _, info := range infos {
		detail, err := info.Info()
		if err != nil {
			continue
		}
		entries = append(entries, fileEntry{
			Name:     info.Name(),
			Dir:      info.IsDir(),
			Size:     detail.Size(),
			Modified: detail.ModTime().Format("2006-01-02 15:04"),
		})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Dir != entries[j].Dir {
			return entries[i].Dir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
	writeFilesJSON(writer, http.StatusOK, map[string]any{
		"ok":      true,
		"path":    relativeToRoot(full),
		"entries": entries,
	})
}

func filesGetHandler(writer http.ResponseWriter, request *http.Request) {
	full, err := resolveFilePath(request.URL.Query().Get("path"))
	if err != nil {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("invalid_path"))
		return
	}
	info, err := os.Stat(full)
	if err != nil || info.IsDir() {
		writeFilesJSON(writer, http.StatusNotFound, errorBody("file_not_found"))
		return
	}
	file, err := os.Open(full)
	if err != nil {
		writeFilesJSON(writer, http.StatusNotFound, errorBody("file_not_found"))
		return
	}
	defer file.Close()
	if request.URL.Query().Get("download") == "1" {
		writer.Header().Set("Content-Disposition", "attachment; filename=\""+strings.ReplaceAll(info.Name(), "\"", "")+"\"")
	}
	http.ServeContent(writer, request, info.Name(), info.ModTime(), file)
}

const filesMaxUpload = 1 << 30

func filesUploadHandler(writer http.ResponseWriter, request *http.Request) {
	dir, err := resolveFilePath(request.URL.Query().Get("path"))
	if err != nil {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("invalid_path"))
		return
	}
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		writeFilesJSON(writer, http.StatusNotFound, errorBody("path_not_found"))
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, filesMaxUpload)
	if err := request.ParseMultipartForm(32 << 20); err != nil {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("invalid_upload"))
		return
	}
	source, header, err := request.FormFile("file")
	if err != nil {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("missing_file"))
		return
	}
	defer source.Close()
	name := filepath.Base(header.Filename)
	if name == "." || name == string(filepath.Separator) || name == "" {
		writeFilesJSON(writer, http.StatusBadRequest, errorBody("invalid_filename"))
		return
	}
	target := filepath.Join(dir, name)
	output, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		writeFilesJSON(writer, http.StatusInternalServerError, errorBody("save_failed"))
		return
	}
	written, copyErr := io.Copy(output, source)
	closeErr := output.Close()
	if copyErr != nil || closeErr != nil {
		writeFilesJSON(writer, http.StatusInternalServerError, errorBody("save_failed"))
		return
	}
	controlLog("files upload %s (%d bytes)", relativeToRoot(target), written)
	writeFilesJSON(writer, http.StatusOK, map[string]any{"ok": true, "path": relativeToRoot(target), "size": written})
}

const filesPageTemplate = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="dark">
<title>文件管理</title>
<style>
:root{font-family:ui-sans-serif,system-ui,sans-serif;color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;min-height:100dvh;background:#020617;color:#e2e8f0;display:flex;flex-direction:column}
header{position:sticky;top:0;background:#0f172a;border-bottom:1px solid #1e293b;padding:14px 16px;z-index:2}
.crumbs{font-size:14px;color:#94a3b8;word-break:break-all}
.crumbs b{color:#f8fafc;font-weight:600}
main{flex:1;overflow-y:auto;padding:10px 12px 90px}
.row{display:flex;align-items:center;gap:12px;padding:13px 14px;border-radius:14px;background:#0f172a;border:1px solid #1e293b;margin-bottom:8px;cursor:pointer}
.row:active{background:#1e293b}
.icon{width:36px;height:36px;border-radius:10px;display:grid;place-items:center;font-size:15px;flex:none;background:#1e3a5f;color:#93c5fd}
.icon.d{background:#143d2b;color:#86efac}
.meta{flex:1;min-width:0}
.name{font-size:15px;color:#f1f5f9;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sub{font-size:12px;color:#64748b;margin-top:2px}
#preview{position:fixed;inset:0;background:#020617;display:none;flex-direction:column;z-index:5}
#preview header{display:flex;gap:10px;align-items:center}
#preview .t{flex:1;font-size:14px;color:#f8fafc;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#pbody{flex:1;overflow:auto;padding:14px}
#pbody img{max-width:100%;border-radius:12px}
#pbody pre{font-size:13px;line-height:1.6;color:#cbd5e1;white-space:pre-wrap;word-break:break-all;background:#0f172a;padding:14px;border-radius:12px;border:1px solid #1e293b}
.btn{border:0;border-radius:10px;padding:9px 14px;background:#2563eb;color:#fff;font:inherit;font-size:14px;cursor:pointer}
.btn.ghost{background:#1e293b;color:#cbd5e1}
#uploadBtn{position:fixed;right:16px;bottom:20px;z-index:3;border-radius:99px;width:56px;height:56px;font-size:22px;box-shadow:0 10px 30px rgba(0,0,0,.5)}
#toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:#1e293b;color:#f8fafc;padding:10px 16px;border-radius:99px;font-size:13px;display:none;z-index:9}
</style>
</head>
<body>
<header><div class="crumbs" id="crumbs"></div></header>
<main id="list"></main>
<button class="btn" id="uploadBtn" title="上传">＋</button>
<input type="file" id="fileInput" style="display:none">
<div id="preview"><header><button class="btn ghost" onclick="closePreview()">返回</button><div class="t" id="ptitle"></div><button class="btn" id="pdl">下载</button></header><div id="pbody"></div></div>
<div id="toast"></div>
<script>
let cwd = "/";
const $ = id => document.getElementById(id);
const textExt = new Set("txt md json log go py js ts kt kts xml yaml yml toml ini csv html css ps1 sh bat cmd c cc cpp h hpp java rs swift sql vue jsx tsx conf cfg env gitignore properties".split(" "));
const imgExt = new Set("png jpg jpeg gif webp bmp svg ico".split(" "));
function ext(n){const i=n.lastIndexOf(".");return i<0?"":n.slice(i+1).toLowerCase()}
function fmtSize(s){if(s<1024)return s+" B";if(s<1048576)return (s/1024).toFixed(1)+" KB";if(s<1073741824)return (s/1048576).toFixed(1)+" MB";return (s/1073741824).toFixed(2)+" GB"}
function toast(m){const t=$("toast");t.textContent=m;t.style.display="block";setTimeout(()=>t.style.display="none",2200)}
async function nav(p){cwd=p;const r=await fetch("/api/list?path="+encodeURIComponent(p));const d=await r.json();if(!d.ok){toast("无法打开");return}
cwd=d.path;renderCrumbs();const list=$("list");list.innerHTML="";
if(cwd!=="/"){list.appendChild(row({name:"..",dir:true},"../"))}
for(const e of d.entries){list.appendChild(row(e))}}
function renderCrumbs(){const parts=cwd.split("/").filter(Boolean);let h="<b>文件管理</b>  / ";let acc="";parts.forEach((p,i)=>{acc+="/"+p;h+=(i?" / ":"")+p});$("crumbs").innerHTML=h}
function row(e){const div=document.createElement("div");div.className="row";
const isUp=e.name==="..";
div.innerHTML='<div class="icon '+(e.dir?"d":"")+'">'+(e.dir?"▸":"◇")+'</div><div class="meta"><div class="name"></div><div class="sub">'+(e.dir?"文件夹":fmtSize(e.size)+(e.modified?" · "+e.modified:""))+"</div></div>";
div.querySelector(".name").textContent=e.name;
div.onclick=()=>{if(e.dir){nav(isUp?cwd.split("/").slice(0,-1).join("/")||"/":(cwd==="/"?"":cwd)+"/"+e.name)}else{preview(e.name)}};
return div}
async function preview(name){const p=(cwd==="/"?"":cwd)+"/"+name;const u="/api/file?path="+encodeURIComponent(p);
$("ptitle").textContent=name;$("pdl").onclick=()=>{location.href=u+"&download=1"};
const body=$("pbody");body.innerHTML="加载中…";$("preview").style.display="flex";
const e=ext(name);
if(imgExt.has(e)){body.innerHTML='<img src="'+u+'">';}
else if(textExt.has(e)){const r=await fetch(u);const t=await r.text();body.innerHTML="";const pre=document.createElement("pre");pre.textContent=t;body.appendChild(pre);}
else{body.innerHTML='<p style="color:#94a3b8;padding:20px">此文件类型不支持预览，请下载查看。</p>'}}
function closePreview(){$("preview").style.display="none";$("pbody").innerHTML=""}
$("uploadBtn").onclick=()=>$("fileInput").click();
$("fileInput").onchange=async ev=>{const f=ev.target.files[0];if(!f)return;
const fd=new FormData();fd.append("file",f);
const r=await fetch("/api/upload?path="+encodeURIComponent(cwd),{method:"POST",body:fd});
const d=await r.json();toast(d.ok?"已上传":"上传失败");ev.target.value="";nav(cwd)};
nav("/");
</script>
</body>
</html>`

func filesHandler(writer http.ResponseWriter, request *http.Request) {
	switch {
	case request.URL.Path == "/" && request.Method == http.MethodGet:
		body := []byte(filesPageTemplate)
		writer.Header().Set("Content-Type", "text/html; charset=utf-8")
		writer.Header().Set("Content-Length", strconv.Itoa(len(body)))
		writer.Header().Set("Cache-Control", "no-store")
		writer.WriteHeader(http.StatusOK)
		_, _ = writer.Write(body)
	case request.URL.Path == "/api/list" && request.Method == http.MethodGet:
		filesListHandler(writer, request)
	case request.URL.Path == "/api/file" && request.Method == http.MethodGet:
		filesGetHandler(writer, request)
	case request.URL.Path == "/api/upload" && request.Method == http.MethodPost:
		filesUploadHandler(writer, request)
	default:
		writeFilesJSON(writer, http.StatusNotFound, errorBody("not_found"))
	}
}

func serveFiles() {
	server := &http.Server{
		Addr:              filesListenAddr,
		Handler:           http.HandlerFunc(filesHandler),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       90 * time.Second,
	}
	controlLog("files manager listening on %s, root %s", filesListenAddr, filesRoot)
	if err := server.ListenAndServe(); err != nil {
		os.Exit(1)
	}
}
