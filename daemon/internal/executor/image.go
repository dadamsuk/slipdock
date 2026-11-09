package executor

import (
	"errors"
	"fmt"
	"regexp"
	"strings"
)

// An image name is data from the server (a runner's config): it runs only
// if it is a well-formed reference and matches a pattern in the machine's
// own allow-list (container_images in its ceiling, #2577).

// imageRef is a container image reference as Docker and Podman read one:
// an optional registry (with a port), a lower-case path, an optional tag
// and an optional sha256 digest. It starts with a letter or digit, so it
// can never read as an option, and holds no space, quote or control
// character.
var imageRef = regexp.MustCompile(`^` +
	`(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?)*(?::[0-9]{1,5})?/)?` +
	`[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*` +
	`(?::[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?` +
	`(?:@sha256:[a-f0-9]{64})?$`)

const maxImage = 255

// ValidImage says why ref can't be an image name, or nil.
func ValidImage(ref string) error {
	if ref == "" {
		return errors.New("no image is named")
	}
	if len(ref) > maxImage || !imageRef.MatchString(ref) {
		return fmt.Errorf("%q is not an image name (registry/path:tag or @sha256:digest)", ref)
	}
	return nil
}

var patternChars = regexp.MustCompile(`^[A-Za-z0-9._:/@*-]+$`)

// maxStars keeps matching cheap.
const maxStars = 4

// ValidImagePattern says why p can't be an allow-list pattern, or nil. A
// pattern is an image name in which * stands for any run of characters
// but /. Its first part (up to the first /, : or @: the registry, or the
// name of an image without one) is written out, so no pattern allows
// every image.
func ValidImagePattern(p string) error {
	if p == "" || len(p) > maxImage || !patternChars.MatchString(p) {
		return fmt.Errorf("%q is not an image pattern (an image name, * for any run of characters but /)", p)
	}
	if strings.Count(p, "*") > maxStars {
		return fmt.Errorf("%q: at most %d * in a pattern", p, maxStars)
	}
	first := p
	if i := strings.IndexAny(p, "/:@"); i >= 0 {
		first = p[:i]
	}
	if first == "" || strings.Contains(first, "*") {
		return fmt.Errorf("%q: write out the registry, or the image's name, before any *", p)
	}
	return nil
}

// MatchImage says whether image matches pattern: * matches any run of
// characters but /, every other character only itself.
func MatchImage(pattern, image string) bool {
	for len(pattern) > 0 {
		if pattern[0] == '*' {
			rest := pattern[1:]
			for i := 0; i <= len(image); i++ {
				if MatchImage(rest, image[i:]) {
					return true
				}
				if i < len(image) && image[i] == '/' {
					return false
				}
			}
			return false
		}
		if image == "" || image[0] != pattern[0] {
			return false
		}
		pattern, image = pattern[1:], image[1:]
	}
	return image == ""
}

// ImageAllowed says why image may not run on a machine whose allow-list is
// patterns, or nil. An empty list allows nothing, and a pattern that isn't
// valid allows nothing.
func ImageAllowed(image string, patterns []string) error {
	if err := ValidImage(image); err != nil {
		return err
	}
	var valid []string
	for _, p := range patterns {
		if ValidImagePattern(p) == nil {
			valid = append(valid, p)
		}
	}
	if len(valid) == 0 {
		return fmt.Errorf("image %q is refused: this machine allows no images (container_images in its ceiling is empty)", image)
	}
	for _, p := range valid {
		if MatchImage(p, image) {
			return nil
		}
	}
	return fmt.Errorf("image %q is not on this machine's allow-list (container_images in its ceiling: %s)", image, strings.Join(valid, ", "))
}
