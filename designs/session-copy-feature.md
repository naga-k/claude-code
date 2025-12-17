# Feature Design: Cross-Workspace Session Resume

## Overview

This document describes a feature that allows users to resume Claude Code sessions in a different workspace/directory than where they were originally created, while optionally preserving session permissions.

## Motivation

### Problem Statement

Currently, Claude Code sessions are bound to their original working directory (`cwd`). When you run `/resume` or `--resume`, you can only see and resume sessions that belong to your current directory. This creates friction when:

- You want to continue a conversation in a different but related project
- You're working in a monorepo and want to carry context between packages
- You accidentally started a session in the wrong directory
- You want to reuse permissions you've already granted in another session

### Key Insight

The session ID is already visible in the status line. Users should be able to use this ID to resume any session from any directory.

## Proposed Design

### Enhanced Resume Command

#### CLI: `--resume` with Session ID

```bash
# Current behavior: resume by name (only shows sessions from cwd)
claude --resume my-session

# New: resume by session ID from ANY directory
claude --resume abc123

# New: resume by session ID and move session to current directory
claude --resume abc123 --relocate

# New: resume and keep original permissions
claude --resume abc123 --with-permissions
```

#### REPL: `/resume` Enhancements

```
# Current: shows only sessions from current directory
/resume

# New: show ALL sessions across all workspaces
/resume --all

# New: resume specific session by ID
/resume abc123

# New: resume with permissions from that session
/resume abc123 --with-permissions
```

### Behavior Options

| Flag | Behavior |
|------|----------|
| `--resume <id>` | Resume session, update its cwd to current directory |
| `--resume <id> --keep-cwd` | Resume session but keep original cwd (read-only context) |
| `--resume <id> --with-permissions` | Resume and apply the session's saved permissions |
| `--relocate` | Permanently change the session's home directory |

### Session Resume Modes

#### Mode 1: Resume in New Directory (Default)
```bash
cd /new/project
claude --resume abc123
```
- Session resumes with conversation history intact
- `cwd` updates to `/new/project`
- Permissions reset (fresh start for new directory)
- Session now "lives" in the new directory

#### Mode 2: Resume with Permissions
```bash
cd /new/project
claude --resume abc123 --with-permissions
```
- Same as above, but permissions carry over
- Useful when projects have similar trust requirements
- Warning shown if permissions reference paths from old cwd

#### Mode 3: Peek at Session (Keep Original CWD)
```bash
cd /somewhere/else
claude --resume abc123 --keep-cwd
```
- Resume session but operations still target original directory
- Useful for reviewing/continuing work without relocating
- Session stays associated with original workspace

### Updated `/resume` UI

```
> /resume --all

Sessions across all workspaces:
┌──────────────────────────────────────────────────────────────────────┐
│ Search: _                                          [A]ll workspaces  │
├──────────────────────────────────────────────────────────────────────┤
│ ID       Name              Directory                    Last Used    │
├──────────────────────────────────────────────────────────────────────┤
│ abc123   my-api-session    /home/user/api              2h ago       │
│ def456   fix-auth-bug      /home/user/api              1d ago       │
│ ghi789   refactor-db       /home/user/backend          3d ago    ←  │
│ jkl012   frontend-work     /home/user/frontend         1w ago       │
└──────────────────────────────────────────────────────────────────────┘
                                    [P]review  [W]ith-permissions  [R]elocate

Selected: ghi789 (from /home/user/backend)
Current directory: /home/user/new-backend

Resume options:
  ● Resume here (move session to current directory)
  ○ Resume with permissions
  ○ Peek (keep original directory)

[Enter] Confirm  [Esc] Cancel
```

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| A | Toggle all workspaces / current workspace only |
| P | Preview session transcript |
| W | Resume with permissions |
| R | Relocate session to current directory |
| Enter | Resume with selected options |
| Esc | Cancel |

## Data Model Changes

### Session Record

```typescript
interface Session {
  id: string;
  name?: string;
  cwd: string;                    // Current working directory
  originalCwd?: string;           // Track where session was created
  transcript_path: string;
  permissions: PermissionRule[];
  createdAt: Date;
  lastAccessedAt: Date;
  relocated: boolean;             // Has session been moved?
  relocationHistory?: string[];   // Track past cwds
}
```

### Permission Portability

```typescript
interface PermissionRule {
  tool: string;
  pattern: string;
  pathType: 'absolute' | 'relative' | 'any';  // New field
}

// When resuming with permissions:
// - 'relative' paths: rebase to new cwd
// - 'absolute' paths: keep as-is (with warning if inaccessible)
// - 'any' patterns (like "*.ts"): transfer directly
```

## Implementation Details

### Session Lookup Changes

Current:
```typescript
function findSessions(cwd: string): Session[] {
  return db.sessions.filter(s => s.cwd === cwd);
}
```

New:
```typescript
function findSessions(options: { cwd?: string; all?: boolean }): Session[] {
  if (options.all) {
    return db.sessions.all();
  }
  return db.sessions.filter(s => s.cwd === options.cwd);
}

function findSessionById(id: string): Session | null {
  return db.sessions.findById(id);
}
```

### Resume Flow

```
┌─────────────────────────────────────────────────────────────┐
│                   claude --resume abc123                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│              Session Lookup (by ID, global)                 │
│  - Search all sessions, not just current cwd                │
│  - Return session metadata                                  │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Permission Handling                        │
│  - If --with-permissions: migrate permissions               │
│  - Rebase relative paths to new cwd                         │
│  - Warn about inaccessible absolute paths                   │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Update Session CWD                         │
│  - Set cwd to current directory (unless --keep-cwd)         │
│  - Track in relocationHistory                               │
│  - Update lastAccessedAt                                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Resume Session                             │
│  - Load transcript                                          │
│  - Initialize with migrated permissions                     │
│  - Start REPL                                               │
└─────────────────────────────────────────────────────────────┘
```

## Permission Migration

### Example: Rebasing Permissions

Original session in `/home/user/api`:
```json
{
  "permissions": [
    { "tool": "Edit", "pattern": "src/**/*.ts", "pathType": "relative" },
    { "tool": "Bash", "pattern": "npm test", "pathType": "any" },
    { "tool": "Read", "pattern": "/etc/hosts", "pathType": "absolute" }
  ]
}
```

After `--resume abc123 --with-permissions` in `/home/user/new-api`:
```json
{
  "permissions": [
    { "tool": "Edit", "pattern": "src/**/*.ts", "pathType": "relative" },  // Works in new cwd
    { "tool": "Bash", "pattern": "npm test", "pathType": "any" },          // Transfers as-is
    { "tool": "Read", "pattern": "/etc/hosts", "pathType": "absolute" }    // Kept (still valid)
  ]
}
```

### Warning Messages

```
⚠ Some permissions reference paths that may not exist in the new directory:
  - Edit: "config/database.yml" (file not found)

Continue anyway? [y/N]
```

## Use Cases

### 1. Wrong Directory Start
```bash
# Accidentally started in home directory
cd ~
claude
# ... did a lot of work, granted permissions ...

# Realize mistake, want to move to actual project
cd ~/my-project
claude --resume abc123 --with-permissions --relocate
```

### 2. Monorepo Package Hopping
```bash
# Working on backend
cd ~/monorepo/packages/backend
claude --resume backend-session

# Need to hop to frontend but keep context
cd ~/monorepo/packages/frontend
claude --resume backend-session  # Context preserved, permissions reset
```

### 3. Reusing Permissions Template
```bash
# Have a session with all your preferred permissions
cd ~/new-project
claude --resume trusted-session --with-permissions
# New project immediately has your permission setup
```

## Error Handling

| Situation | Behavior |
|-----------|----------|
| Session ID not found | "Session 'abc123' not found. Use `/resume --all` to see all sessions." |
| Permission path invalid | Warning + prompt to continue |
| Session currently active elsewhere | "Session is active in another terminal. Force resume? [y/N]" |

## Security Considerations

1. **Permission scope**: Warn when permissions from a different cwd might grant unintended access
2. **Sensitive paths**: Flag absolute paths to sensitive locations (e.g., `~/.ssh`)
3. **Audit trail**: Log when permissions are migrated between workspaces

## Implementation Phases

### Phase 1: Basic Cross-Workspace Resume
- [ ] Enable `--resume <id>` to find sessions globally
- [ ] Update session cwd on resume
- [ ] Add `--all` flag to `/resume` command

### Phase 2: Permission Handling
- [ ] Add `--with-permissions` flag
- [ ] Implement permission path rebasing
- [ ] Add warnings for invalid paths

### Phase 3: UI Enhancements
- [ ] Update `/resume` screen with all-workspaces view
- [ ] Add keyboard shortcuts (A, W, R)
- [ ] Show session origin directory

### Phase 4: Advanced Options
- [ ] Add `--keep-cwd` mode
- [ ] Track relocation history
- [ ] Add `--relocate` for permanent moves

## Comparison: Copy vs Resume

| Aspect | Copy (Original Design) | Resume (This Design) |
|--------|------------------------|----------------------|
| Creates new session | Yes | No |
| Preserves session ID | No | Yes |
| Duplicates transcript | Yes | No |
| Complexity | Higher | Lower |
| Use case | Branching/backup | Mobility |

This design is simpler and addresses the core need: **using sessions across directories**.

## Open Questions

1. Should there be a way to "bookmark" a session ID for easy access?
2. Should sessions auto-detect if they've been resumed in a git-related directory?
3. Limit on how many directories a session can be relocated to?
