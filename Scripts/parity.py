#!/usr/bin/env python3
"""Builds a throwaway context for every case, runs the classic `docker build`, and records where each context file
ended up in the final image (file contents are unique, so the image's files are traced back by content). Runtime
cases build on `swift:6.0` (any image with a shell works) and record what a command prints in the container.
Writes the results as a Swift fixture.

Usage: python3 -I Scripts/parity.py Tests/DockerfileClaimKitTests/ParityFixture.swift
Needs a running Docker daemon and the swift:6.0 image. Removes every image and container it makes.
"""
import io, os, subprocess, sys, tarfile, tempfile

S = "FROM scratch\n"
# (name, Dockerfile, context files, .dockerignore or None)
CASES = [
    ("directory no slash", S + "COPY src /app\n", ["src/index.js", "src/lib/a.js"], None),
    ("directory slash", S + "COPY src /app/\n", ["src/index.js"], None),
    ("directory source slash", S + "COPY src/ /app\n", ["src/index.js"], None),
    ("directory into named", S + "COPY src /app/src/\n", ["src/index.js"], None),
    ("file no slash", S + "COPY a.txt /app\n", ["a.txt"], None),
    ("file slash", S + "COPY a.txt /app/\n", ["a.txt"], None),
    ("file into workdir", S + "WORKDIR /app\nCOPY a.txt /app\n", ["a.txt"], None),
    ("file into copied dir", S + "COPY b.txt /app/\nCOPY a.txt /app\n", ["a.txt", "b.txt"], None),
    ("file into parent of copy", S + "COPY b.txt /app/x/\nCOPY a.txt /app\n", ["a.txt", "b.txt"], None),
    ("two files no slash", S + "COPY a.txt b.txt /app\n", ["a.txt", "b.txt"], None),
    ("two files workdir no slash", S + "WORKDIR /app\nCOPY a.txt b.txt /app\n", ["a.txt", "b.txt"], None),
    ("two files slash", S + "COPY a.txt b.txt /app/\n", ["a.txt", "b.txt"], None),
    ("two files dot", S + "WORKDIR /app\nCOPY a.txt b.txt .\n", ["a.txt", "b.txt"], None),
    ("two files variable destination", S + "ENV D=/app/\nCOPY a.txt b.txt $D\n", ["a.txt", "b.txt"], None),
    ("glob dot", S + "WORKDIR /app\nCOPY *.txt .\n", ["a.txt", "b.txt"], None),
    ("file dot", S + "WORKDIR /app\nCOPY a.txt .\n", ["a.txt"], None),
    ("glob one match no slash", S + "COPY *.txt /app\n", ["a.txt", "c.md"], None),
    ("glob two matches no slash", S + "COPY *.txt /app\n", ["a.txt", "b.txt"], None),
    ("glob two matches slash", S + "COPY *.txt /app/\n", ["a.txt", "b.txt", "c.md"], None),
    ("glob flattens", S + "COPY src/*.js /app/\n", ["src/a.js", "src/b.js", "src/sub/c.js"], None),
    ("glob matches directory", S + "COPY sr* /app/\n", ["src/a.js", "src/sub/c.js", "srv.txt"], None),
    ("glob star in directory", S + "COPY src/* /app/\n", ["src/a.js", "src/sub/c.js"], None),
    ("double star is one level", S + "COPY src/**/*.js /app/\n", ["src/a.js", "src/sub/c.js", "src/x/y/d.js"], None),
    ("question mark", S + "COPY ?.txt /app/\n", ["a.txt", "ab.txt"], None),
    ("class", S + "COPY [ab].txt /app/\n", ["a.txt", "b.txt", "c.txt"], None),
    ("negated class", S + "COPY [^a].txt /app/\n", ["a.txt", "b.txt"], None),
    ("relative no workdir", S + "COPY a.txt app/\n", ["a.txt"], None),
    ("relative workdir", S + "WORKDIR /srv\nCOPY a.txt app/\n", ["a.txt"], None),
    ("dot dot", S + "WORKDIR /srv\nCOPY . .\n", ["a.txt", "d/b.txt"], None),
    ("relative workdir chain", S + "WORKDIR /a\nWORKDIR b\nCOPY x.txt .\n", ["x.txt"], None),
    ("workdir parent", S + "WORKDIR /a/b\nWORKDIR ..\nCOPY x.txt ./\n", ["x.txt"], None),
    ("dot source", S + "COPY . /app\n", ["a.txt", "src/b.js"], None),
    ("dot slash source", S + "COPY ./src /app/\n", ["src/b.js"], None),
    ("root destination", S + "COPY a.txt /\n", ["a.txt"], None),
    ("json form", S + 'COPY ["src", "/app/"]\n', ["src/a.js"], None),
    ("json form variable", S + 'ENV D=j\nCOPY ["a.txt", "/$D/"]\n', ["a.txt"], None),
    ("outside context", S + "COPY ../x /app/\n", ["a.txt"], None),
    ("ignored file", S + "COPY a.txt b.txt /app/\n", ["a.txt", "b.txt"], "a.txt\n"),
    ("ignored inside directory", S + "COPY src /app/\n", ["src/a.js", "src/b.log"], "**/*.log\n"),
    ("ignored with dot", S + "COPY . /app/\n", ["a.txt", "node_modules/x.js"], "node_modules\n"),
    ("arg before from", "ARG D=pre\n" + S + "COPY a.txt /$D/\n", ["a.txt"], None),
    ("arg redeclared", "ARG D=pre\n" + S + "ARG D\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("arg redeclared default", "ARG D=pre\n" + S + "ARG D=in\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("arg in from", "ARG BASE=scratch\nFROM $BASE\nCOPY a.txt /x/\n", ["a.txt"], None),
    ("arg in stage", S + "ARG D=in\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("env in stage", S + "ENV D=e\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("env other stage", "FROM scratch AS b\nENV D=e\n" + S + "COPY a.txt /$D/\n", ["a.txt"], None),
    ("env chained stage", "FROM scratch AS b\nENV D=e\nFROM b\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("arg chained stage", "FROM scratch AS b\nARG D=e\nFROM b\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("workdir chained stage", "FROM scratch AS b\nWORKDIR /w\nFROM b\nCOPY a.txt .\n", ["a.txt"], None),
    ("workdir other stage", "FROM scratch AS b\nWORKDIR /w\n" + S + "COPY a.txt ./\n", ["a.txt"], None),
    ("copy from stage", "FROM scratch AS b\nCOPY src /out/\n" + S + "COPY --from=b /out /dst\n",
     ["src/a.js", "src/s/b.js"], None),
    ("copy from stage file", "FROM scratch AS b\nCOPY a.txt /out/\n" + S + "COPY --from=b /out/a.txt /dst/\n",
     ["a.txt"], None),
    ("copy from stage index", S + "COPY a.txt /o/\n" + S + "COPY --from=0 /o /p/\n", ["a.txt"], None),
    ("files from chained stage", "FROM scratch AS b\nCOPY a.txt /out/\nFROM b\nCOPY c.txt /out/\n",
     ["a.txt", "c.txt"], None),
    ("default value", S + "COPY a.txt /${D:-dflt}/\n", ["a.txt"], None),
    ("alternate value", S + "ENV D=x\nCOPY a.txt /${D:+alt}/\n", ["a.txt"], None),
    ("braces", S + "ENV D=x\nCOPY a.txt /${D}y/\n", ["a.txt"], None),
    ("escaped dollar", S + "COPY a.txt /\\$D/\n", ["a.txt"], None),
    ("legacy env", S + "ENV D e\nCOPY a.txt /$D/\n", ["a.txt"], None),
    ("env pairs", S + "ENV A=1 B=2\nCOPY a.txt /$A$B/\n", ["a.txt"], None),
    ("env same line", S + "ENV A=1 B=$A\nCOPY a.txt /x$B/\n", ["a.txt"], None),
    ("env quoted", S + 'ENV A="p q"\nCOPY a.txt "/$A/"\n', ["a.txt"], None),
    ("workdir variable", S + "ENV W=/w\nWORKDIR $W/x\nCOPY a.txt .\n", ["a.txt"], None),
    ("continuation", S + "COPY a.txt \\\n  /cont/\n", ["a.txt"], None),
    ("comment in continuation", S + "COPY a.txt \\\n# note\n  /cc/\n", ["a.txt"], None),
    ("lowercase", S + "copy a.txt /lc/\n", ["a.txt"], None),
    ("escape directive", "# escape=`\n" + S + "COPY a.txt `\n  /tick/\n", ["a.txt"], None),
    ("copy twice", S + "COPY a.txt /one/\nCOPY a.txt /two/\n", ["a.txt"], None),
]

RUNTIME = [
    ("run cd alone", "FROM swift:6.0\nRUN mkdir -p /app && cd /app\nRUN pwd > /out\n", "cat /out"),
    ("arg before from in run", "ARG V=1\nFROM swift:6.0\nRUN echo \"[$V]\" > /out\n", "cat /out"),
    ("arg redeclared in run", "ARG V=1\nFROM swift:6.0\nARG V\nRUN echo \"[$V]\" > /out\n", "cat /out"),
    ("arg at runtime", "FROM swift:6.0\nARG V=1\n", "sh -c 'echo [$V]'"),
    ("arg kept by env", "FROM swift:6.0\nARG V=1\nENV V=$V\n", "sh -c 'echo [$V]'"),
    ("exec form variable", "FROM swift:6.0\nENV P=8080\nCMD [\"echo\", \"$P\"]\n", ""),
    ("exec form shell", "FROM swift:6.0\nENV P=8080\nCMD [\"sh\", \"-c\", \"echo $P\"]\n", ""),
    ("shell form arg", "FROM swift:6.0\nARG P=8080\nCMD echo \"[$P]\"\n", ""),
]


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def build(number, dockerfile, files, ignore):
    with tempfile.TemporaryDirectory(prefix="dfc-parity-") as root:
        for path in files:
            full = os.path.join(root, path)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "w") as handle:
                handle.write(path + "\n")
        with open(os.path.join(root, "Dockerfile"), "w") as handle:
            handle.write(dockerfile)
        if ignore is not None:
            with open(os.path.join(root, ".dockerignore"), "w") as handle:
                handle.write(ignore)
        tag = f"dfc-parity:{number}"
        built = run(["docker", "build", "-q", "-t", tag, root])
        if built.returncode != 0:
            return None
        container = run(["docker", "create", tag, "/none"]).stdout.strip()
        exported = subprocess.run(["docker", "export", container], capture_output=True).stdout
        run(["docker", "rm", container])
        run(["docker", "rmi", tag])
        found = {path: [] for path in files}
        for member in tarfile.open(fileobj=io.BytesIO(exported)).getmembers():
            if not member.isfile() or member.size > 200:
                continue
            content = tarfile.open(fileobj=io.BytesIO(exported)).extractfile(member.name).read().decode()
            if content.endswith("\n") and content[:-1] in found:
                found[content[:-1]].append("/" + member.name)
        return {path: sorted(paths) for path, paths in found.items()}


def runtime(number, dockerfile, command):
    with tempfile.TemporaryDirectory(prefix="dfc-runtime-") as root:
        with open(os.path.join(root, "Dockerfile"), "w") as handle:
            handle.write(dockerfile)
        tag = f"dfc-runtime:{number}"
        built = run(["docker", "build", "-q", "-t", tag, root])
        assert built.returncode == 0, built.stderr
        args = ["docker", "run", "--rm", tag] + (["sh", "-c", command] if command else [])
        output = run(args).stdout.strip()
        run(["docker", "rmi", tag])
        return output


def swift(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def main(out):
    server = run(["docker", "version", "--format", "{{.Server.Version}}"]).stdout.strip()
    lines = [f"// Generated by Scripts/parity.py from the classic `docker build` (Docker {server}). Do not edit.",
             "", "let parityCases: [ParityCase] = ["]
    for number, (name, dockerfile, files, ignore) in enumerate(CASES):
        result = build(number, dockerfile, files, ignore)
        ignore_text = swift(ignore) if ignore is not None else "nil"
        if result is None:
            placed = "nil"
        else:
            entries = ", ".join(f"{swift(p)}: [{', '.join(swift(x) for x in result[p])}]" for p in files)
            placed = "[" + entries + "]"
        lines.append(f"    ParityCase(name: {swift(name)}, dockerfile: {swift(dockerfile)}, dockerignore: {ignore_text},")
        lines.append(f"               files: {swift(chr(10).join(files))}, placed: {placed}),")
        print(name, "->", result, file=sys.stderr)
    lines += ["]", "", "let runtimeCases: [RuntimeCase] = ["]
    for number, (name, dockerfile, command) in enumerate(RUNTIME):
        output = runtime(number, dockerfile, command)
        lines.append(f"    RuntimeCase(name: {swift(name)}, dockerfile: {swift(dockerfile)}, output: {swift(output)}),")
        print(name, "->", output, file=sys.stderr)
    lines += ["]", ""]
    with open(out, "w") as handle:
        handle.write("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1])
