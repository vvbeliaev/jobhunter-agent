.PHONY: run nanobot browser

nanobot:
	uv sync --upgrade-package nanobot-ai

browser:
	bash scripts/start-browser.sh

run:
	uv run nanobot gateway --config ./.nanobot/workspace/config.json