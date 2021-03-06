## Part of 'koch' responsible for the documentation generation.

import os, strutils, osproc, sets

const
  gaCode* = " --doc.googleAnalytics:UA-48159761-1"
  # --warning[LockLevel]:off pending #13218
  nimArgs = "--warning[LockLevel]:off --hint[Conf]:off --hint[Path]:off --hint[Processing]:off -d:boot --putenv:nimversion=$#" % system.NimVersion
  gitUrl = "https://github.com/nim-lang/Nim"
  docHtmlOutput = "doc/html"
  webUploadOutput = "web/upload"
  docHackDir = "tools/dochack"

var nimExe*: string

proc exe*(f: string): string =
  result = addFileExt(f, ExeExt)
  when defined(windows):
    result = result.replace('/','\\')

proc findNim*(): string =
  if nimExe.len > 0: return nimExe
  var nim = "nim".exe
  result = "bin" / nim
  if existsFile(result): return
  for dir in split(getEnv("PATH"), PathSep):
    if existsFile(dir / nim): return dir / nim
  # assume there is a symlink to the exe or something:
  return nim

proc exec*(cmd: string, errorcode: int = QuitFailure, additionalPath = "") =
  let prevPath = getEnv("PATH")
  if additionalPath.len > 0:
    var absolute = additionalPath
    if not absolute.isAbsolute:
      absolute = getCurrentDir() / absolute
    echo("Adding to $PATH: ", absolute)
    putEnv("PATH", (if prevPath.len > 0: prevPath & PathSep else: "") & absolute)
  echo(cmd)
  if execShellCmd(cmd) != 0: quit("FAILURE", errorcode)
  putEnv("PATH", prevPath)

template inFold*(desc, body) =
  if existsEnv("TRAVIS"):
    echo "travis_fold:start:" & desc.replace(" ", "_")

  body

  if existsEnv("TRAVIS"):
    echo "travis_fold:end:" & desc.replace(" ", "_")

proc execFold*(desc, cmd: string, errorcode: int = QuitFailure, additionalPath = "") =
  ## Execute shell command. Add log folding on Travis CI.
  # https://github.com/travis-ci/travis-ci/issues/2285#issuecomment-42724719
  inFold(desc):
    exec(cmd, errorcode, additionalPath)

proc execCleanPath*(cmd: string,
                   additionalPath = ""; errorcode: int = QuitFailure) =
  # simulate a poor man's virtual environment
  let prevPath = getEnv("PATH")
  when defined(windows):
    let cleanPath = r"$1\system32;$1;$1\System32\Wbem" % getEnv"SYSTEMROOT"
  else:
    const cleanPath = r"/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/X11/bin"
  putEnv("PATH", cleanPath & PathSep & additionalPath)
  echo(cmd)
  if execShellCmd(cmd) != 0: quit("FAILURE", errorcode)
  putEnv("PATH", prevPath)

proc nimexec*(cmd: string) =
  # Consider using `nimCompile` instead
  exec findNim().quoteShell() & " " & cmd

proc nimCompile*(input: string, outputDir = "bin", mode = "c", options = "") =
  let output = outputDir / input.splitFile.name.exe
  let cmd = findNim().quoteShell() & " " & mode & " -o:" & output & " " & options & " " & input
  exec cmd

proc nimCompileFold*(desc, input: string, outputDir = "bin", mode = "c", options = "") =
  let output = outputDir / input.splitFile.name.exe
  let cmd = findNim().quoteShell() & " " & mode & " -o:" & output & " " & options & " " & input
  execFold(desc, cmd)

const
  pdf = """
doc/manual.rst
doc/lib.rst
doc/tut1.rst
doc/tut2.rst
doc/tut3.rst
doc/nimc.rst
doc/niminst.rst
doc/gc.rst
""".splitWhitespace()

  rst2html = """
doc/intern.rst
doc/apis.rst
doc/lib.rst
doc/manual.rst
doc/manual_experimental.rst
doc/destructors.rst
doc/tut1.rst
doc/tut2.rst
doc/tut3.rst
doc/nimc.rst
doc/hcr.rst
doc/overview.rst
doc/filters.rst
doc/tools.rst
doc/niminst.rst
doc/nimgrep.rst
doc/gc.rst
doc/estp.rst
doc/idetools.rst
doc/docgen.rst
doc/koch.rst
doc/backends.rst
doc/nimsuggest.rst
doc/nep1.rst
doc/nims.rst
doc/contributing.rst
doc/codeowners.rst
doc/packaging.rst
doc/manual/var_t_return.rst
""".splitWhitespace()

  doc0 = """
lib/system/threads.nim
lib/system/channels.nim
""".splitWhitespace() # ran by `nim doc0` instead of `nim doc`

  withoutIndex = """
lib/wrappers/mysql.nim
lib/wrappers/iup.nim
lib/wrappers/sqlite3.nim
lib/wrappers/postgres.nim
lib/wrappers/tinyc.nim
lib/wrappers/odbcsql.nim
lib/wrappers/pcre.nim
lib/wrappers/openssl.nim
lib/posix/posix.nim
lib/posix/linux.nim
lib/posix/termios.nim
lib/js/jscore.nim
""".splitWhitespace()

  ignoredModules = """
lib/pure/future.nim
lib/impure/osinfo_posix.nim
lib/impure/osinfo_win.nim
lib/pure/collections/hashcommon.nim
lib/pure/collections/tableimpl.nim
lib/pure/collections/setimpl.nim
lib/pure/ioselects/ioselectors_kqueue.nim
lib/pure/ioselects/ioselectors_select.nim
lib/pure/ioselects/ioselectors_poll.nim
lib/pure/ioselects/ioselectors_epoll.nim
lib/posix/posix_macos_amd64.nim
lib/posix/posix_other.nim
lib/posix/posix_nintendoswitch.nim
lib/posix/posix_nintendoswitch_consts.nim
lib/posix/posix_linux_amd64.nim
lib/posix/posix_linux_amd64_consts.nim
lib/posix/posix_other_consts.nim
lib/posix/posix_openbsd_amd64.nim
""".splitWhitespace()
  # some of these (eg lib/posix/posix_macos_amd64.nim) are include files
  # but contain potentially valuable docs on OS-specific symbols (eg OSX) that
  # don't end up in the main docs; we ignore these for now.

when (NimMajor, NimMinor) < (1, 1) or not declared(isRelativeTo):
  proc isRelativeTo(path, base: string): bool =
    # pending #13212 use os.isRelativeTo
    let path = path.normalizedPath
    let base = base.normalizedPath
    let ret = relativePath(path, base)
    result = path.len > 0 and not ret.startsWith ".."

proc getDocList(): seq[string] =
  var t: HashSet[string]
  for a in doc0:
    doAssert a notin t
    t.incl a
  for a in withoutIndex:
    doAssert a notin t, a
    t.incl a

  for a in ignoredModules:
    doAssert a notin t, a
    t.incl a

  var t2: HashSet[string]
  template myadd(a)=
    result.add a
    doAssert a notin t2, a
    t2.incl a

  # don't ignore these even though in lib/system
  const goodSystem = """
lib/system/io.nim
lib/system/nimscript.nim
lib/system/assertions.nim
lib/system/iterators.nim
lib/system/dollars.nim
lib/system/widestrs.nim
""".splitWhitespace()

  for a in walkDirRec("lib"):
    if a.splitFile.ext != ".nim": continue
    if a.isRelativeTo("lib/pure/includes"): continue
    if a.isRelativeTo("lib/genode"): continue
    if a.isRelativeTo("lib/deprecated"):
      if a notin @["lib/deprecated/pure/ospaths.nim"]: # REMOVE
        continue
    if a.isRelativeTo("lib/system"):
      if a notin goodSystem:
        continue
    if a notin t:
      result.add a
      doAssert a notin t2, a
      t2.incl a

  myadd "nimsuggest/sexp.nim"
  # these are include files, even though some of them don't specify `included from ...`
  const ignore = """
compiler/ccgcalls.nim
compiler/ccgexprs.nim
compiler/ccgliterals.nim
compiler/ccgstmts.nim
compiler/ccgthreadvars.nim
compiler/ccgtrav.nim
compiler/ccgtypes.nim
compiler/jstypes.nim
compiler/semcall.nim
compiler/semexprs.nim
compiler/semfields.nim
compiler/semgnrc.nim
compiler/seminst.nim
compiler/semmagic.nim
compiler/semobjconstr.nim
compiler/semstmts.nim
compiler/semtempl.nim
compiler/semtypes.nim
compiler/sizealignoffsetimpl.nim
compiler/suggest.nim
compiler/packagehandling.nim
compiler/hlo.nim
compiler/rodimpl.nim
compiler/vmops.nim
compiler/vmhooks.nim
""".splitWhitespace()

  # not include files but doesn't work; not included/imported anywhere; dead code?
  const bad = """
compiler/debuginfo.nim
compiler/canonicalizer.nim
compiler/forloops.nim
""".splitWhitespace()

  # these cause errors even though they're imported (some of which are mysterious)
  const bad2 = """
compiler/closureiters.nim
compiler/tccgen.nim
compiler/lambdalifting.nim
compiler/layouter.nim
compiler/evalffi.nim
compiler/nimfix/nimfix.nim
compiler/plugins/active.nim
compiler/plugins/itersgen.nim
""".splitWhitespace()

  for a in walkDirRec("compiler"):
    if a.splitFile.ext != ".nim": continue
    if a in ignore: continue
    if a in bad: continue
    if a in bad2: continue
    result.add a

let doc = getDocList()

proc sexec(cmds: openArray[string]) =
  ## Serial queue wrapper around exec.
  for cmd in cmds:
    echo(cmd)
    let (outp, exitCode) = osproc.execCmdEx(cmd)
    if exitCode != 0: quit outp

proc mexec(cmds: openArray[string]) =
  ## Multiprocessor version of exec
  let r = execProcesses(cmds, {poStdErrToStdOut, poParentStreams, poEchoCmd})
  if r != 0:
    echo "external program failed, retrying serial work queue for logs!"
    sexec(cmds)

proc buildDocSamples(nimArgs, destPath: string) =
  ## Special case documentation sample proc.
  ##
  ## TODO: consider integrating into the existing generic documentation builders
  ## now that we have a single `doc` command.
  exec(findNim().quoteShell() & " doc $# -o:$# $#" %
    [nimArgs, destPath / "docgen_sample.html", "doc" / "docgen_sample.nim"])

proc buildDoc(nimArgs, destPath: string) =
  # call nim for the documentation:
  var
    commands = newSeq[string](rst2html.len + len(doc0) + len(doc) + withoutIndex.len)
    i = 0
  let nim = findNim().quoteShell()
  for d in items(rst2html):
    commands[i] = nim & " rst2html $# --git.url:$# -o:$# --index:on $#" %
      [nimArgs, gitUrl,
      destPath / changeFileExt(splitFile(d).name, "html"), d]
    i.inc
  for d in items(doc0):
    commands[i] = nim & " doc0 $# --git.url:$# -o:$# --index:on $#" %
      [nimArgs, gitUrl,
      destPath / changeFileExt(splitFile(d).name, "html"), d]
    i.inc
  for d in items(doc):
    var nimArgs2 = nimArgs
    if d.isRelativeTo("compiler"):
      nimArgs2.add " --docroot"
    commands[i] = nim & " doc $# --git.url:$# --outdir:$# --index:on $#" %
      [nimArgs2, gitUrl, destPath, d]
    i.inc
  for d in items(withoutIndex):
    commands[i] = nim & " doc2 $# --git.url:$# -o:$# $#" %
      [nimArgs, gitUrl,
      destPath / changeFileExt(splitFile(d).name, "html"), d]
    i.inc

  mexec(commands)
  exec(nim & " buildIndex -o:$1/theindex.html $1" % [destPath])

proc buildPdfDoc*(nimArgs, destPath: string) =
  createDir(destPath)
  if os.execShellCmd("pdflatex -version") != 0:
    echo "pdflatex not found; no PDF documentation generated"
  else:
    const pdflatexcmd = "pdflatex -interaction=nonstopmode "
    for d in items(pdf):
      exec(findNim().quoteShell() & " rst2tex $# $#" % [nimArgs, d])
      # call LaTeX twice to get cross references right:
      exec(pdflatexcmd & changeFileExt(d, "tex"))
      exec(pdflatexcmd & changeFileExt(d, "tex"))
      # delete all the crappy temporary files:
      let pdf = splitFile(d).name & ".pdf"
      let dest = destPath / pdf
      removeFile(dest)
      moveFile(dest=dest, source=pdf)
      removeFile(changeFileExt(pdf, "aux"))
      if existsFile(changeFileExt(pdf, "toc")):
        removeFile(changeFileExt(pdf, "toc"))
      removeFile(changeFileExt(pdf, "log"))
      removeFile(changeFileExt(pdf, "out"))
      removeFile(changeFileExt(d, "tex"))

proc buildJS() =
  exec(findNim().quoteShell() & " js -d:release --out:$1 tools/nimblepkglist.nim" %
      [webUploadOutput / "nimblepkglist.js"])
  exec(findNim().quoteShell() & " js " & (docHackDir / "dochack.nim"))

proc buildDocs*(args: string) =
  const
    docHackJs = "dochack.js"
  let
    a = nimArgs & " " & args
    docHackJsSource = docHackDir / docHackJs
    docHackJsDest = docHtmlOutput / docHackJs

  buildJS()                     # This call generates docHackJsSource
  let docup = webUploadOutput / NimVersion
  createDir(docup)
  buildDocSamples(a, docup)
  buildDoc(a, docup)

  # 'nimArgs' instead of 'a' is correct here because we don't want
  # that the offline docs contain the 'gaCode'!
  createDir(docHtmlOutput)
  buildDocSamples(nimArgs, docHtmlOutput)
  buildDoc(nimArgs, docHtmlOutput)
  copyFile(docHackJsSource, docHackJsDest)
  copyFile(docHackJsSource, docup / docHackJs)
