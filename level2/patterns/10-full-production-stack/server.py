"""Production server launcher."""
import subprocess
import sys

def main():
    args = ["vllm", "serve"] + sys.argv[1:]
    subprocess.run(args, check=True)

if __name__ == "__main__":
    main()
