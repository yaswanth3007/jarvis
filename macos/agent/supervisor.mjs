#!/usr/bin/env node
// The background agent moved to core/supervisor.mjs, shared by macOS, Windows and Linux.
// Kept here so the LaunchAgent installed by earlier versions (local.jarvis.agent) keeps working.
import '../../core/supervisor.mjs'
