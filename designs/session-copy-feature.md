# Feature Design: Copy Sessions Between Workspaces

## Overview

This document describes the design for a feature that allows users to copy Claude Code sessions from one workspace/directory to another. This enables transferring conversation context, permissions, and history between different projects or directories.

## Motivation

### Problem Statement

Currently, Claude Code sessions are bound to specific working directories (`cwd`). Users cannot:
- Move a session's context to a new project
- Share conversation history between related projects
- Duplicate a productive session to use as a starting point in another workspace
- Transfer learned context (like project architecture understanding) to related codebases

### Use Cases

1. **Monorepo Navigation**: Copy a session from one package to another within a monorepo
2. **Project Forking**: When forking a project, bring along the Claude session that understands the codebase
3. **Context Transfer**: Apply learned context about an architecture to a similar project
4. **Session Backup**: Create a copy of an important session in a different location
5. **Team Sharing**: Export session context that teammates can import into their workspace

## Existing Session Features

| Feature | CLI Flag | REPL Command | Description |
|---------|----------|--------------|-------------|
| Resume | `--resume <name>` | `/resume <name>` | Resume a named session |
| Continue | `--continue` | - | Resume most recent session |
| Rename | - | `/rename <name>` | Name the current session |
| Teleport | `--teleport` | - | Transfer session from web to CLI |
| Export | - | `/export` | Export conversation for sharing |

## Proposed Design

### New Commands

#### CLI Flag: `--copy-session`

```bash
# Copy session to current directory
claude --copy-session <session-name-or-id>

# Copy session to a specific target directory
claude --copy-session <session-name-or-id> --target /path/to/target

# Copy from a specific source directory
claude --copy-session <session-name-or-id> --source /path/to/source --target /path/to/target
```

#### REPL Command: `/copy-session`

```
/copy-session <session-name> [target-path]
```

Interactive mode with prompts:
1. If no session name provided, show session picker (similar to `/resume`)
2. If no target path provided, prompt for destination directory
3. Confirm copy with preview of what will be transferred

### Session Copy Behavior

#### What Gets Copied

| Component | Copied | Notes |
|-----------|--------|-------|
| Transcript history | Yes | Full conversation history |
| Session name | Yes* | Appended with "-copy" or user-specified name |
| Session ID | No | New ID generated for the copy |
| Working directory (cwd) | Updated | Set to target directory |
| Permissions | Optional | User can choose to copy or reset |
| Git branch tracking | Reset | Cleared as target may have different git state |

#### Copy Options

```bash
# Copy with all permissions
claude --copy-session my-session --target /new/project --copy-permissions

# Copy without permissions (fresh start, default)
claude --copy-session my-session --target /new/project

# Copy and immediately start the session
claude --copy-session my-session --target /new/project --start

# Copy with a new name
claude --copy-session my-session --target /new/project --name "new-session-name"
```

### Data Structures

#### Session Copy Request

```typescript
interface SessionCopyRequest {
  sourceSessionId: string;
  sourceWorkspace?: string;  // Optional, defaults to current
  targetWorkspace: string;
  options: SessionCopyOptions;
}

interface SessionCopyOptions {
  newName?: string;           // Name for the copied session
  copyPermissions: boolean;   // Whether to copy permission rules
  startAfterCopy: boolean;    // Immediately start the copied session
  transcriptOnly: boolean;    // Only copy transcript, reset all settings
}
```

#### Session Copy Result

```typescript
interface SessionCopyResult {
  success: boolean;
  newSessionId: string;
  newSessionName: string;
  targetWorkspace: string;
  copiedComponents: string[];  // List of what was copied
  warnings: string[];          // Any warnings during copy
}
```

### User Interface

#### Interactive Mode Flow

```
> /copy-session

Select a session to copy:
┌─────────────────────────────────────────────────────────────┐
│ Search: _                                                   │
├─────────────────────────────────────────────────────────────┤
│ ● my-api-project          /home/user/api          2h ago   │
│   fix-auth-bug            /home/user/api          1d ago   │
│   refactor-db             /home/user/backend      3d ago   │
│   frontend-redesign       /home/user/frontend     1w ago   │
└─────────────────────────────────────────────────────────────┘
                                                    [P]review

Selected: my-api-project

Target directory: /home/user/new-api-project

Copy options:
  [x] Copy transcript history
  [ ] Copy permissions (recommended: start fresh)
  [ ] Start session after copy

Confirm copy? [y/N]

✓ Session copied successfully!
  New session: my-api-project-copy
  Location: /home/user/new-api-project

  To start: cd /home/user/new-api-project && claude --resume my-api-project-copy
```

#### Keyboard Shortcuts (in session picker)

| Key | Action |
|-----|--------|
| Enter | Select session for copy |
| P | Preview session transcript |
| / | Search/filter sessions |
| Esc | Cancel |

### Implementation Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     CLI Entry Point                         │
│                  claude --copy-session                      │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Session Manager                            │
│  - Validate source session exists                           │
│  - Validate target directory                                │
│  - Check for conflicts                                      │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Session Copier                             │
│  - Read source session data                                 │
│  - Transform transcript paths                               │
│  - Generate new session ID                                  │
│  - Update cwd references                                    │
└─────────────────────┬───────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────────┐
│                  Storage Layer                              │
│  - Write new session to target workspace storage            │
│  - Copy transcript file                                     │
│  - Index new session                                        │
└─────────────────────────────────────────────────────────────┘
```

### Hook Integration

#### New Hook Event: `SessionCopy`

```json
{
  "SessionCopy": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "echo 'Session copied: $SESSION_SOURCE -> $SESSION_TARGET'"
        }
      ]
    }
  ]
}
```

Hook input:
```json
{
  "session_id": "new-session-id",
  "source_session_id": "original-session-id",
  "source_cwd": "/original/path",
  "target_cwd": "/new/path",
  "hook_event_name": "SessionCopy"
}
```

### Error Handling

| Error Condition | Behavior |
|-----------------|----------|
| Source session not found | Error with list of available sessions |
| Target directory doesn't exist | Prompt to create or error |
| Target has existing session with same name | Prompt to rename or overwrite |
| Insufficient permissions on target | Clear error message |
| Copy fails mid-process | Rollback, clean up partial copy |

### Edge Cases

1. **Circular copy**: Copying session back to its original workspace
   - Allow with warning, create as new session

2. **Cross-user copy**: Copying to a directory owned by different user
   - Respect file system permissions, fail gracefully

3. **Large transcripts**: Sessions with very large conversation history
   - Stream copy for large files, show progress indicator

4. **Active sessions**: Copying a session that's currently running
   - Allow copy of snapshot, warn that new messages won't be included

5. **Git state mismatch**: Target has different git branch/repo
   - Clear git tracking info, let session adapt to new context

## Alternative Designs Considered

### Option A: Session Export/Import (File-based)

```bash
# Export to file
claude --export-session my-session > session.json

# Import in new directory
cd /new/project && claude --import-session session.json
```

**Pros**:
- Simple, portable format
- Easy to share via email/slack
- Version controllable

**Cons**:
- Two-step process
- File management overhead
- Potential for stale exports

### Option B: Session Linking (Symlink-style)

```bash
# Link session to additional directory
claude --link-session my-session /new/project
```

**Pros**:
- No data duplication
- Changes sync automatically

**Cons**:
- Complexity in managing linked sessions
- Confusion about which workspace "owns" the session
- Git tracking issues

### Option C: Session Clone with Smart Context (Chosen Approach)

The proposed design creates an independent copy that can diverge, similar to git clone. This provides:
- Clear ownership semantics
- Independence between source and copy
- Flexibility to adapt to new codebase

## Security Considerations

1. **Permission Isolation**: By default, don't copy permissions to prevent accidental privilege escalation
2. **Transcript Privacy**: Ensure copied transcripts don't leak sensitive info from source project
3. **Path Sanitization**: Validate and sanitize all path inputs
4. **Session Integrity**: Verify session data integrity after copy

## Implementation Phases

### Phase 1: Core Copy Functionality
- [ ] Implement `--copy-session` CLI flag
- [ ] Basic session copy with transcript and metadata
- [ ] Target directory validation
- [ ] New session ID generation

### Phase 2: Interactive Mode
- [ ] Add `/copy-session` REPL command
- [ ] Session picker UI
- [ ] Copy options dialog
- [ ] Progress indicator for large sessions

### Phase 3: Advanced Features
- [ ] `SessionCopy` hook event
- [ ] Permission copy option
- [ ] Cross-workspace session search
- [ ] Batch copy multiple sessions

### Phase 4: Polish
- [ ] Session preview before copy
- [ ] Undo/rollback capability
- [ ] Session copy history tracking
- [ ] Integration with VS Code extension

## Testing Strategy

### Unit Tests
- Session data transformation
- Path rewriting
- ID generation
- Validation logic

### Integration Tests
- End-to-end copy flow
- Cross-directory operations
- Permission handling
- Hook integration

### Manual Testing Scenarios
1. Copy named session to new project
2. Copy session with large transcript
3. Copy to non-existent directory (with creation prompt)
4. Copy with permission transfer
5. Interrupt copy mid-process

## Open Questions

1. **Session Deduplication**: Should we detect and prevent duplicate copies?
2. **Merge Support**: Should there be a way to merge sessions from different workspaces?
3. **History Pruning**: Option to copy only recent N messages?
4. **Selective Copy**: Copy only specific parts of a session (certain conversations)?

## Appendix

### Related Features
- Session resume: `--resume`, `/resume`
- Session teleport: `--teleport`
- Session export: `/export`
- Session forking (internal, via UI)

### References
- CHANGELOG.md - Session feature history
- plugins/plugin-dev/skills/hook-development/SKILL.md - Hook system documentation
