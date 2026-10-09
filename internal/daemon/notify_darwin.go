package daemon

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"
)

const notificationTimeout = 10 * time.Second
const maxNotificationBodyRunes = 240

// postUserNotification shows a Notification Center banner without needing the
// menu bar app. Title and body are passed as arguments, never as script text.
func postUserNotification(title string, body string) {
	if runes := []rune(body); len(runes) > maxNotificationBodyRunes {
		body = string(runes[:maxNotificationBodyRunes]) + "…"
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), notificationTimeout)
		defer cancel()
		cmd := exec.CommandContext(
			ctx,
			"/usr/bin/osascript",
			"-e", "on run argv",
			"-e", "display notification (item 2 of argv) with title (item 1 of argv)",
			"-e", "end run",
			title,
			body,
		)
		if err := cmd.Run(); err != nil {
			fmt.Fprintf(os.Stderr, "post notification: %v\n", err)
		}
	}()
}
