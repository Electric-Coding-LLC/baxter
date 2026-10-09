//go:build !darwin

package daemon

func postUserNotification(title string, body string) {}
