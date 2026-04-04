.PHONY: run nanobot browser

install:
	uv sync --upgrade-package nanobot-ai

run:
	uv run nanobot gateway --config ./.nanobot/config.json