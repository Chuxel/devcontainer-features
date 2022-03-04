const yaml = require('js-yaml');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const actionPath = process.env.GITHUB_ACTION_PATH;
let featureId = process.env.ACTIONS_SHIM_FEATURE_ID;
let featureIdEnvName = featureId.toUpperCase().replace(/-/g, "_");
let optionPrefix = "_BUILD_ARG_" + featureIdEnvName; 

// Dumb function to convert https://docs.github.com/en/actions/learn-github-actions/contexts 
// to related environment variables. For example, convert strings like ${{ github.token }} to the value of GITHUB_TOKEN
function convertContexts(value) {
    if (typeof (value) !== 'string') {
        return value;
    }
    let converted = value;
    const variableStrings = value.match(/\$\{\{[^}]+\}\}/g);
    if (variableStrings) {
        variableStrings.forEach((variableString) => {
            let varName = variableString.substring(3, variableString.length - 2).trim();
            varName = varName.toUpperCase().replace(/\./g, '_');
            let varValue = process.env[varName];
            if (typeof (varValue) === 'undefined') {
                varValue = '';
            }
            converted = converted.replace(variableString, varValue);
        })
    }
    return converted;
}

async function runScript(scriptPath) {
    console.log("Executing " + scriptPath);
    let command = 'node';
    let args = [path.join(actionPath, scriptPath)];
    let opts = { stdio: 'pipe', env: process.env };
    return new Promise((resolve, reject) => {
        let result = '';
        const proc = spawn(command, args, opts);
        proc.on('close', (code, signal) => {
            if (code !== 0) {
                const err = new Error(`Non-zero exit code: ${code} ${signal || ''}`);
                err.result = result;
                err.code = code;
                err.signal = signal;
                reject(err);
                return;
            }
            resolve(result);
        });
        if (proc.stdout) {
            proc.stdout.on('data', (chunk) => {
                const stringChunk = chunk.toString();
                result += stringChunk;
                process.stdout.write(stringChunk);
            });
        }
        if (proc.stderr) {
            proc.stderr.on('data', (chunk) => {
                const stringChunk = chunk.toString();
                result += stringChunk;
                process.stderr.write(stringChunk);
            });
        }
        proc.on('error', reject);
    });
}

function convertEnvVars(result) {
    let variableStrings = result.match(/::set-env\s+name=.+::.+/g);
    if (!variableStrings) {
        return '';
    }

    let envString = '';
    variableStrings.forEach((variableString) => {
        let parts = variableString.split('::');
        let name = parts[1].split('=')[1];
        let value = parts[2];
        envString += `export ${name}="${value.replace('"', '\\"')}"\n`;
    });
    return envString;
}

function convertPath(result) {
    let pathStrings = result.match(/::add-path::.+/g);
    if (!pathStrings) {
        return '';
    }

    let pathString = '';
    pathStrings.forEach((variableString) => {
        let parts = variableString.split('::');
        pathString += `export PATH="${parts[2]}:$\{PATH}"\n`;
    });
    return pathString;
}


(async function () {

    // Mimic behavior of https://github.com/actions/runner/blob/main/src/Runner.Worker/Handlers/NodeScriptActionHandler.cs
    const actionYaml = yaml.load(fs.readFileSync(path.join(actionPath, 'action.yml'), 'utf8'));

    // Run "inputs" in yaml and, if found, convert _BUILD_ARG variables and mimic INPUT_ vars based on:
    // https://github.com/actions/runner/blob/ad0d0c4d0a9e58943a688f66586b4dadf524ad9f/src/Runner.Worker/Handlers/Handler.cs#L169
    for (input in actionYaml.inputs) {
        let settings = actionYaml.inputs[input];
        let varName = input.toUpperCase();
        let inputVarName = 'INPUT_' + varName;
        let inputVarValue = process.env[inputVarName];
        if (!inputVarValue || typeof (inputVarValue) === 'undefined') {
            let buildArgVarName = optionPrefix + "_" + varName;
            buildArgVarName = buildArgVarName.replace(/-/g, "_");
            optionValue = process.env[buildArgVarName];
            if (typeof (optionValue) !== 'undefined') {
                console.log('Input ' + input + ' set to ' + optionValue);
                process.env[inputVarName] = optionValue;
            } else {
                if (typeof(settings.default) !== 'undefined') {
                    let defaultVal = convertContexts(settings.default)
                    console.log('Setting ' + input + ' to default ' + defaultVal);
                    process.env[inputVarName] = convertContexts(defaultVal);
                }
            }
        } else {
            console.log('Input ' + input + ' already set to ' + inputVarValue);
        }
    }

    // https://github.dev/actions/runner/blob/ad0d0c4d0a9e58943a688f66586b4dadf524ad9f/src/Runner.Sdk/ProcessInvoker.cs#L197
    process.env.GITHUB_ACTIONS = true
    process.env.CI = true
    let result = '';
    // TODO implement "pre-if"
    if (actionYaml.runs.pre) {
        result += await runScript(actionYaml.runs.pre);
    }
    result += await runScript(actionYaml.runs.main);
    // TODO implement "post-if"
    if (actionYaml.runs.post) {
        result += await runScript(actionYaml.runs.post);
    }
    // TODO implement success

    let envString = convertEnvVars(result);
    envString += convertPath(result);
    fs.writeFileSync(path.join(process.env.ACTION_SHIM_PROFILE_D, 'action-' + featureId + '-env.sh'), envString);
}());

