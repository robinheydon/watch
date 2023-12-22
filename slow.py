import random
import time
import sys

time.sleep (0.1)

for _ in range (100):
    x = random.randint (1, 100)
    time.sleep (0.01)
    sys.stdout.flush ()
    print (f"{'#'*x}")
