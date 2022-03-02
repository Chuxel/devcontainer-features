//go:build !windows

package common

import (
	"io/fs"
	"os"

	"golang.org/x/sys/unix"
)

func SyncUIDGID(targetFile *os.File, sourceFileInfo fs.FileInfo) {
	targetFile.Chown(int(sourceFileInfo.Sys().(*unix.Stat_t).Uid), int(sourceFileInfo.Sys().(*unix.Stat_t).Gid))
}
