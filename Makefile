.PHONY: clean

clean:
	rm -f sim/generated_stimulus.v sim/supercycle_sim sim/tb_output.csv sim/seq_test sim/seq_test.vcd
	rm -rf __pycache__ sim/__pycache__ sequencer/__pycache__
