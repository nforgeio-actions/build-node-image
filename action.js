//-----------------------------------------------------------------------------
// FILE:        action.js
// CONTRIBUTOR: Jeff Lill
// COPYRIGHT:   Copyright (c) 2005-2021 by neonFORGE LLC.  All rights reserved.
//
// The contents of this repository are for private use by neonFORGE, LLC. and may not be
// divulged or used for any purpose by other organizations or individuals without a
// formal written and signed agreement with neonFORGE, LLC.

// This script acts as a bridge between the GitHub runner and our Powershell script
// that actually does all the work.  This is necessary because workflow composite 
// run steps (where Powershell code can be executed directly) doesn't appear to
// support features like action inputs/outputs.  This appears to be by-design.

const core = require('@actions/core');
const exec = require("child_process").exec;

// Set the current directory to the folder where this script is located, which 
// will be the root folder for the action files. 

process.chdir(__dirname);

// Launch the Powershell script.

exec("pwsh -NonInteractive -File action.ps1", { maxBuffer: 4096 * 1024 },
    function (err, stdout, stderr) {

        process.stdout.write(stdout);
        process.stderr.write(stderr);

        if (err) {
            core.setFailed(`Action failed: ${err}`);
        }
    });
