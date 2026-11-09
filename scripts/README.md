# Scripts

Catch-up scripts for the labs. `catch-up.sh NN` replays Labs 01 to NN-1 on a fresh machine so you can start Lab NN. The `labNN-catch-up.sh` scripts replay a single lab and can be run on their own.

```bash
~/intermediate-devops-companion/scripts/catch-up.sh 04
```

## Helper Scripts

- `start-harness.sh`: Starts or restarts the local Harness Open Source container on the `devops` network and waits until it is ready at `http://localhost:3000`.

```bash
~/intermediate-devops-companion/scripts/start-harness.sh
```

