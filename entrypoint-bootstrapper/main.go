package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const bootstrapScriptsPath = "/usr/local/etc/dev-container-features/entrypoint.d"
const bootstrapUserFileExtension = ".user"
const entrypointDoneEnvVarName = "DEV_CONTAINER_ENTRYPOINTS_DONE"
const cnbUserIdEnvVarName = "CNB_USER_ID"
const devContainerUserIdEnvVarName = "DEV_CONTAINER_USER_ID"

type NonZeroExitError struct {
	ExitCode int
}

func (err NonZeroExitError) Error() string {
	return "Non-zero exit code: " + strconv.FormatInt(int64(err.ExitCode), 10)
}

func main() {
	// Fire executables in entrypoint.d if not already fired
	if os.Getenv(entrypointDoneEnvVarName) != "true" {
		files, err := os.ReadDir(bootstrapScriptsPath)
		if err != nil && !os.IsNotExist(err) {
			log.Fatal("Failed to read contents of entrypoint.d folder: ", err)
		}
		workingDir, err := os.Getwd()
		if err != nil {
			log.Fatal("Failed to get working directory: ", err)
		}
		for _, file := range files {
			// If is an executable file, execute it
			if file.Type().IsRegular() && file.Type().Perm()&0001 != 0 {
				executeScript(filepath.Join(bootstrapScriptsPath, file.Name()), workingDir, os.Environ())
			}
		}
	}

	args := os.Args
	env := append(os.Environ(), entrypointDoneEnvVarName+"=true")
	userName := os.Getenv(cnbUserIdEnvVarName)
	if userName == "" {
		userName = os.Getenv(devContainerUserIdEnvVarName)
		if userName == "" {
			currentExec, err := os.Executable()
			if err != nil {
				log.Fatal("Failed to get executable path: ", err)
			}
			if _, err := os.Stat(currentExec + bootstrapUserFileExtension); err == nil {
				fileBytes, err := os.ReadFile(currentExec + bootstrapUserFileExtension)
				if err != nil {
					log.Fatal("Failed to read .user file: ", err)
				}
				userName = strings.TrimSpace(string(fileBytes))
			}
		}
	}
	execCmd := ""
	var execArgs []string
	if userName != "" {
		execCmd = "runuser"
		execArgs = []string{"-u", userName, "--"}
		execArgs = append(execArgs, args[1:]...)
	} else {
		// Root user
		execCmd = args[1]
		execArgs = args[2:]
	}
	if err := unix.Exec(execCmd, execArgs, env); err != nil {
		log.Fatal("Failed to execute command", execCmd, execArgs, err)
	}
}

func executeScript(scriptPath string, cwd string, env []string) {
	// Execute the script
	log.Printf("- Executing %s\n", scriptPath)
	logWriter := log.Writer()
	command := exec.Command(scriptPath)
	command.Env = env
	command.Stdout = logWriter
	command.Stderr = logWriter
	command.Dir = cwd
	if err := command.Run(); err != nil {
		log.Fatal("Error executing", scriptPath, err)
	}
	if command.ProcessState.ExitCode() != 0 {
		log.Fatal("Error executing", scriptPath, "-  Exit code", command.ProcessState.ExitCode())
	}
}
