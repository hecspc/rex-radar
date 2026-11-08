// Pi extension → Rex Radar: lets Rex Radar show and answer the questions Pi asks with
// @juicesharp/rpiv-ask-user-question's ask_user_question tool, the way it does for Claude Code.
//
// - While a questionnaire waits, reports the pane to Rex as blocked on a question (OSC 7501, root
//   record, as Pi itself reports), since Pi reports a custom dialog as nothing at all, and puts
//   back the `working` Pi would report when it closes. Pi re-reports `working` when the dialog
//   mounts (up to ~0.6 s later, the package loads it lazily), so the report is repeated while
//   the dialog opens, then every 10 s.
// - Saves the question list to ${REX_RADAR_DIR:-~/.local/state/rex-radar}/questions/<REX_BLOCK>.json,
//   in the shape hooks/claude-rex-questions writes, and removes it when the questionnaire closes.
// - Watches answers/<REX_BLOCK>.json for Rex Radar's answer, hands it to the package's inbound
//   rpiv:ask-user:answer event (no keystrokes), and writes the verdict to
//   answers/<REX_BLOCK>.result.json.
//
// Install: ln -s <repo>/hooks/pi-rex-questions.ts ~/.pi/agent/extensions/. Does nothing outside Rex.

import { mkdirSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// The package's public event channels, which its stability policy keeps unchanged.
const PROMPT = "rpiv:ask-user:prompt";
const BLOCKED = "rpiv:ask-user:blocked";
const ANSWER = "rpiv:ask-user:answer";
const ANSWER_RESULT = "rpiv:ask-user:answer-result";

const BLOCK = /^[A-Za-z0-9][A-Za-z0-9:._-]*$/;
const POLL_MS = 400;
/** Repeat the blocked report on every poll this long after it opens, then every REASSERT_MS. */
const OPENING_MS = 4000;
const REASSERT_MS = 10000;

type Question = {
  question: string;
  header?: string;
  multiSelect?: boolean;
  options?: { label: string; description?: string }[];
};

export default function (pi: ExtensionAPI) {
  const block = process.env.REX_BLOCK ?? "";
  if (!BLOCK.test(block)) return;

  const base = process.env.REX_RADAR_DIR || join(homedir(), ".local/state/rex-radar");
  const questionsFile = join(base, "questions", `${block}.json`);
  const answersDir = join(base, "answers");
  const answerFile = join(answersDir, `${block}.json`);
  const resultFile = join(answersDir, `${block}.result.json`);

  /** Prompts by tool call, from the prompt event until their questionnaire closes. */
  const prompts = new Map<string, Question[]>();
  /** Open questionnaires, newest last: the newest is the one shown and reported. */
  const open: string[] = [];
  let timer: ReturnType<typeof setInterval> | undefined;
  let openedAt = 0;
  let reportedAt = 0;

  const report = (state: string, kind?: string, msg?: string) => {
    if (!process.stdout.isTTY) return;
    const pairs = [`state=${state}`, "app=pi"];
    if (kind) pairs.push(`kind=${kind}`);
    // Rex drops a report whose text has control characters; Pi limits msg to 2048 bytes.
    const text = Buffer.from((msg ?? "").replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").trim(), "utf8")
      .subarray(0, 2048)
      .toString("utf8")
      .replace(/\uFFFD$/, "");
    if (text) pairs.push(`msg=${Buffer.from(text, "utf8").toString("base64")}`);
    process.stdout.write(`\x1b]7501;${pairs.join(":")}\x1b\\`);
  };

  const writeAtomic = (file: string, data: unknown) => {
    const tmp = `${file}.tmp.${process.pid}`;
    writeFileSync(tmp, JSON.stringify(data), { mode: 0o600 });
    renameSync(tmp, file);
  };

  const remove = (file: string) => {
    try { unlinkSync(file); } catch {}
  };

  /** Saves the newest open questionnaire for Rex Radar and reports it, or clears both. */
  const publish = () => {
    const id = open.at(-1);
    const questions = id ? prompts.get(id) : undefined;
    try {
      if (id && questions) {
        mkdirSync(join(base, "questions"), { recursive: true, mode: 0o700 });
        writeAtomic(questionsFile, {
          block_id: block,
          session_id: process.env.REX_SESSION ?? "",
          tool_use_id: id,
          asked_at: new Date().toISOString(),
          app: "pi",
          questions: questions.map((q) => ({
            question: q.question,
            header: q.header,
            multiSelect: q.multiSelect ?? false,
            options: (q.options ?? []).map((o) => ({ label: o.label, description: o.description })),
          })),
        });
        report("blocked", "question", questions[0]?.question);
        reportedAt = Date.now();
      } else {
        remove(questionsFile);
        report("working", undefined, pi.getSessionName());
      }
    } catch {}
  };

  /** Hands Rex Radar's answer, if one is waiting, to the questionnaire it names. */
  const poll = () => {
    const now = Date.now();
    if (now - openedAt < OPENING_MS || now - reportedAt > REASSERT_MS) {
      const questions = prompts.get(open.at(-1) ?? "");
      if (questions) {
        report("blocked", "question", questions[0]?.question);
        reportedAt = now;
      }
    }
    let request: any;
    try {
      request = JSON.parse(readFileSync(answerFile, "utf8"));
    } catch {
      return;
    }
    remove(answerFile);
    const requestId = typeof request?.requestId === "string" ? request.requestId : undefined;
    const toolCallId = typeof request?.toolCallId === "string" ? request.toolCallId : undefined;
    if (!toolCallId || !open.includes(toolCallId)) {
      try { writeAtomic(resultFile, { requestId, toolCallId, ok: false, code: "not_found" }); } catch {}
      return;
    }
    pi.events.emit(ANSWER, { toolCallId, requestId, answers: request.answers });
  };

  pi.events.on(ANSWER_RESULT, (data: any) => {
    // Only verdicts for Rex Radar's requests: another extension may answer too.
    if (typeof data?.requestId !== "string" || !data.requestId.startsWith("rex-radar-")) return;
    try {
      writeAtomic(resultFile, {
        requestId: data.requestId, toolCallId: data.toolCallId, ok: data.ok === true, code: data.code, reason: data.reason,
      });
    } catch {}
  });

  pi.events.on(PROMPT, (data: any) => {
    if (typeof data?.toolCallId === "string" && Array.isArray(data.questions)) prompts.set(data.toolCallId, data.questions);
  });

  pi.events.on(BLOCKED, (data: any) => {
    const id = data?.toolCallId;
    if (typeof id !== "string") return;
    const at = open.indexOf(id);
    if (at >= 0) open.splice(at, 1);
    if (data.active === true) {
      open.push(id);
      openedAt = Date.now();
      try { mkdirSync(answersDir, { recursive: true, mode: 0o700 }); } catch {}
      // A stale answer left from an earlier questionnaire must not answer this one.
      remove(answerFile);
      timer ??= setInterval(poll, POLL_MS);
    } else {
      prompts.delete(id);
    }
    if (open.length === 0 && timer) {
      clearInterval(timer);
      timer = undefined;
    }
    publish();
  });

  pi.on("session_shutdown", async () => {
    if (timer) clearInterval(timer);
    if (open.length) remove(questionsFile);
  });
}
