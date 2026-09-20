import { Icon, LaunchType, MenuBarExtra, launchCommand } from "@raycast/api";
import { usePromise } from "@raycast/utils";
import {
  enrichRows,
  mergeRows,
  readLiveSessions,
  readPending,
  readSessions,
  readUsage,
  touchHeartbeat,
  writeVerdict,
  type Row,
} from "./lib/inbox";
import { usageLine, usagePeak } from "./lib/format";
import { age, askPhrase, bySeverity, GROUP_TITLES, LIMITS, projectName, rowTitle, STATES, subjectOf } from "./lib/state";

/** Above this, usage stops being weather and takes over the bar glyph. */
const USAGE_ALERT = 90;

function project(row: Row): string {
  return row.kind === "pending"
    ? projectName(row.pending.cwd, row.pending.session_id)
    : projectName(row.session.cwd, row.session.session_id, row.session.name);
}

function ask(row: Row): string {
  if (row.kind === "pending") return askPhrase(row.pending);
  // A dialog the terminal owns says what it wants; that beats anything we infer.
  return row.session.waiting_for ?? subjectOf(row.session);
}

/** Right-hand text: the step, when the session declared one, and always the age. */
function trailing(row: Row): string {
  const phase = row.kind === "session" ? row.session.phase : undefined;
  return phase ? `${phase} · ${age(row.ts)}` : age(row.ts);
}

/** Five rows, then a submenu. A menu that scrolls has already failed. */
function capped<T>(items: T[], limit: number = LIMITS.menuSection): [T[], T[]] {
  return [items.slice(0, limit), items.slice(limit)];
}

export default function Command() {
  const { data, isLoading, revalidate } = usePromise(async () => {
    await touchHeartbeat("menubar");
    const [pending, sessions, live, usage] = await Promise.all([
      readPending(),
      readSessions(),
      readLiveSessions(),
      readUsage(),
    ]);
    const rows = await enrichRows(mergeRows(pending, sessions, live).sort(bySeverity));
    return { rows, usage };
  });

  const rows = data?.rows ?? [];
  const usage = data?.usage ?? [];
  const waiting = rows.filter((r) => STATES[r.state].group === "waiting");
  const running = rows.filter((r) => STATES[r.state].group === "running");
  const finished = rows.filter((r) => STATES[r.state].group === "finished");
  const peak = usage.reduce((max, u) => Math.max(max, usagePeak(u)), 0);

  // The bar answers one question: am I needed? A count is the whole message.
  const icon = waiting.length ? Icon.Bell : peak >= USAGE_ALERT ? Icon.Warning : running.length ? Icon.CircleFilled : Icon.Circle;
  const title = waiting.length ? String(waiting.length) : undefined;

  async function approve(row: Row) {
    if (row.kind !== "pending") return;
    await writeVerdict(row.pending.req, "allow", "Approved from the menu bar");
    revalidate();
  }

  function openInbox() {
    launchCommand({ name: "inbox", type: LaunchType.UserInitiated }).catch(() => undefined);
  }

  function sessionRows(items: Row[], withApprove: boolean) {
    return items.map((row, index) => (
      <MenuBarExtra.Item
        key={row.id}
        icon={STATES[row.state].icon}
        title={rowTitle(project(row), ask(row))}
        subtitle={trailing(row)}
        // Opening is the safe default; ⌥ turns the row into an approval, so a
        // tool call is never allowed by a misclick.
        shortcut={withApprove && index < 9 ? { modifiers: ["cmd"], key: String(index + 1) as "1" } : undefined}
        onAction={openInbox}
        alternate={
          withApprove ? (
            <MenuBarExtra.Item
              icon={Icon.Check}
              title={`Approve — ${rowTitle(project(row), ask(row))}`}
              onAction={() => approve(row)}
            />
          ) : undefined
        }
      />
    ));
  }

  function section(title: string, items: Row[], withApprove = false) {
    if (!items.length) return null; // empty sections vanish; menus have no room for placeholders
    const [head, rest] = capped(items);
    return (
      <MenuBarExtra.Section title={title}>
        {sessionRows(head, withApprove)}
        {rest.length ? (
          <MenuBarExtra.Submenu title={`${rest.length} more`} icon={Icon.Ellipsis}>
            {sessionRows(rest, withApprove)}
          </MenuBarExtra.Submenu>
        ) : null}
      </MenuBarExtra.Section>
    );
  }

  return (
    <MenuBarExtra
      icon={icon}
      title={title}
      isLoading={isLoading}
      tooltip={waiting.length ? `${waiting.length} waiting for you` : "Claude sessions"}
    >
      {section(GROUP_TITLES.waiting, waiting, true)}
      {section(GROUP_TITLES.running, running)}
      {section(GROUP_TITLES.finished, capped(finished, 3)[0])}

      <MenuBarExtra.Section>
        {usage.map((u) => (
          <MenuBarExtra.Item
            key={u.config_dir}
            icon={usagePeak(u) >= USAGE_ALERT ? Icon.Warning : Icon.BarChart}
            title={usageLine(u)}
            onAction={openInbox}
          />
        ))}
        <MenuBarExtra.Item
          title="Open Inbox"
          icon={Icon.AppWindowList}
          shortcut={{ modifiers: ["cmd", "shift"], key: "c" }}
          onAction={openInbox}
        />
      </MenuBarExtra.Section>
    </MenuBarExtra>
  );
}
