# The wiki over HTTP

Every command in this skill is HTTP underneath. `B` is the server's base URL
and `H` is `Authorization: Bearer $SLIPDOCK_TOKEN`.

`:id` takes a numeric id, a page code (`W-31`), or `board-code/slug` with the
slash URL-encoded (`apiwiki%2Frunbook`).

```sh
# find
curl -s -H "$H" B/api/boards/1/pages                    # ?tree=true ?q= ?parent= ?archived= ?template=
curl -s -H "$H" B/api/boards/1/pages/wanted
curl -s -H "$H" "B/api/pages/resolve?board=1&title=Retry+policy"

# read
curl -s -H "$H" B/api/pages/W-31                        # Markdown source + content_hash
curl -s -H "$H" B/api/pages/W-31/render                 # references resolved; ?format=markdown|html|text
curl -s -H "$H" B/api/pages/W-31/sections
curl -s -H "$H" B/api/pages/W-31/section/Deploy/Rollback

# write
curl -s -H "$H" -H 'content-type: application/json' B/api/boards/1/pages \
     -d '{"title":"Retry policy","body":"# Retry\n\nThree times.","message":"first draft"}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/section/Log -d '{"body":"- 2026-09-29 rolled back"}'
curl -s -X PUT -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/section/Deploy/Rollback -d '{"body":"## Rollback\n\nNew words."}'
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/append -d '{"body":"## Findings\n\n…"}'
curl -s -X PATCH -H "$H" -H 'content-type: application/json' B/api/pages/W-31 \
     -d '{"body":"…","base_hash":"<the content_hash you read>","message":"why"}'

# filing: where a page is kept (folders), as opposed to what it is part of
curl -s -H "$H" B/api/wiki                              # every board, folders and all
curl -s -H "$H" B/api/boards/1/folders                  # one board's filing, nested
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/boards/1/folders -d '{"name":"Design/Decisions"}'   # a path makes every level
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/folder -d '{"folder":"Design/Decisions"}' # made if it is new
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/folder -d '{}'                    # out of its folder
curl -s -H "$H" "B/api/boards/1/pages?folder=decisions" # ?folder=none for the unfiled
curl -s -X PATCH -H "$H" -H 'content-type: application/json' \
     "B/api/boards/1/folders/Design/Decisions" -d '{"name":"Choices","parent":"root"}'
curl -s -X DELETE -H "$H" "B/api/boards/1/folders/Choices"   # keeps everything in it

# shape and graph
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/move -d '{"parent":"W-12","position":"top"}'
curl -s -H "$H" B/api/pages/W-31/links
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/links -d '{"card":412}'          # pin: this page is the spec for that card

# history
curl -s -H "$H" B/api/pages/W-31/revisions
curl -s -H "$H" "B/api/pages/W-31/revisions/12?diff=previous"
curl -s -X POST -H "$H" -H 'content-type: application/json' \
     B/api/pages/W-31/revert -d '{"revision_id":12}'

# away and back
curl -s -X DELETE -H "$H" B/api/pages/W-31             # archive; ?purge=true is permanent, owner only
curl -s -X POST -H "$H" B/api/pages/W-31/restore
```

## The two answers that are not 200

**409 on a PATCH** means the page moved on while you were writing. The body
carries `current` — the page as it now stands, with its `content_hash`. Merge
against that and save again with the new hash. Never retry the same request.

**404 on a page you can see the id of** may mean it is a draft and you are not
a writer on that board. Drafts are hidden rather than refused on purpose: the
page's existence is itself the thing being withheld.

## Provenance

Every write records who made it. `via` is the client — send
`x-slipdock-client: cli` if you are a shell — and `agent` is the name on the API
token, so a page's history distinguishes two agents sharing one account. The
`message` field is the "why"; write one every time.
