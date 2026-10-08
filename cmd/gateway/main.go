// Command gateway is the Crucible LLM inference gateway.
package main

import (
	"log/slog"
	"os"
)

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	log.Info("crucible gateway starting", "status", "scaffold only")
}
