// Tiny long-running app. Holds a secret from the environment in a package
// variable so Part 3 can try to recover it from process memory, and serves it
// at /whoami so it is also live in the heap. Static build, runs in scratch.
package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

var secretInMemory = "unset"

func main() {
	secretInMemory = os.Getenv("APP_SECRET")
	fmt.Println("app started", time.Now().Format(time.RFC3339))
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "ok")
	})
	http.HandleFunc("/whoami", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "secret-len=%d\n", len(secretInMemory))
	})
	http.ListenAndServe(":8080", nil)
}
