package main

import (
	"os"
	"regexp"
	"strings"

	"github.com/gofiber/fiber/v2"
	"github.com/pocketbase/pocketbase"
	"github.com/pocketbase/pocketbase/core"
)

func main() {
	app := pocketbase.New()

	// Only lock in production
	readOnly := os.Getenv("PB_READONLY_ADMIN")
	app.OnBeforeServe().Add(func(e *core.ServeEvent) error {
		if strings.ToLower(readOnly) != "true" {
			return nil
		}

		// Endpoints that mutate schema or admin/system config:
		blocked := []*regexp.Regexp{
			regexp.MustCompile(`^/api/collections/?$`),          // create new collection (POST)
			regexp.MustCompile(`^/api/collections/[^/]+$`),      // update/delete collection (PATCH/DELETE)
			regexp.MustCompile(`^/api/collections/(import|export|truncate)(/|$)`),
			regexp.MustCompile(`^/api/settings$`),               // update instance settings (PATCH)
			regexp.MustCompile(`^/api/admins(/|$)`),             // create/delete admins etc.
			regexp.MustCompile(`^/api/logs(/|$)`),               // log settings/cleanup (defensive)
		}

		e.Router.Use(func(c *fiber.Ctx) error {
			// Only care about mutating methods
			switch c.Method() {
			case fiber.MethodPost, fiber.MethodPut, fiber.MethodPatch, fiber.MethodDelete:
				p := c.Path()
				for _, re := range blocked {
					if re.MatchString(p) {
						return c.Status(fiber.StatusForbidden).JSON(fiber.Map{
							"code":    "read_only_admin",
							"message": "Schema/config changes are disabled in production.",
						})
					}
				}
			}
			return c.Next()
		})
		return nil
	})

	if err := app.Start(); err != nil {
		panic(err)
	}
}