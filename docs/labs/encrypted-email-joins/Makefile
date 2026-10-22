.PHONY: reproduce preflight summary clean

reproduce:
	./reproduce.sh

preflight:
	./scripts/00-preflight.sh

summary:
	cd scripts && ../.venv/bin/python summarize.py > ../results/summary.md

clean:
	rm -rf data
	sudo -u postgres dropdb --if-exists shop
