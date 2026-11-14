reproduce:
	bash scripts/reproduce.sh

preflight:
	bash scripts/preflight.sh

clean:
	-bash scripts/registry-down.sh
	-sudo ip netns del wormlab
	-sudo ip link del veth-wh
	rm -rf .run

.PHONY: reproduce preflight clean
