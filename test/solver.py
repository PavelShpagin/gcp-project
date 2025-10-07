class Solver:
    def __init__(self, workers=None, input_file_name=None, output_file_name=None):
        self.out = output_file_name or "out.txt"
    def solve(self):
        import sys, platform
        with open(self.out, "w") as f:
            f.write("python=" + sys.version + "\nplatform=" + platform.platform() + "\n")
