# Isaac Lab launch profiles

[Back to README](../README.md)

## Custom launch profiles — example (Isaac Lab train → play)

In **Settings ▸ Launch profiles** for a workstation, add named commands that run
verbatim on the box. An Isaac Lab RL workflow is two profiles — train, then, once
training exits (Lab closes the sim automatically), play the trained policy:

```
# Cartpole (Train)
cd ~/Documents/isaaclab_ws/IsaacLab && LIVESTREAM=2 ~/env_isaaclab/bin/python \
  scripts/reinforcement_learning/sb3/train.py --task Isaac-Cartpole-v0 --num_envs 64 --headless \
  --kit_args '--/app/livestream/publicEndpointAddress=<box-ip>'

# Cartpole (Play)   ← launch this from the menu after Train finishes
cd ~/Documents/isaaclab_ws/IsaacLab && LIVESTREAM=2 ~/env_isaaclab/bin/python \
  scripts/reinforcement_learning/sb3/play.py --task Isaac-Cartpole-v0 --num_envs 32 \
  --use_last_checkpoint --headless --kit_args '--/app/livestream/publicEndpointAddress=<box-ip>'
```

They show under **Workstation ▸ Launch ▸ Cartpole (Train) / Cartpole (Play)**;
each fires via `isaac-ctl run` (base64'd over SSH). `--use_last_checkpoint` makes
Play auto-load the newest checkpoint, so Train→Play needs no path edits. Add
`--ext-folder <omni-kit-mcp>/exts --enable omni.kit.mcp` inside `--kit_args` to
co-load the [omni-kit-mcp](https://github.com/inbarajaldrin) bridge for agent
control during the run.
