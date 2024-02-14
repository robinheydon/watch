import random
import time
import sys

time.sleep (0.1)

random.seed (0)

num_lines = random.randint (40, 80)

numbers = '0123456789' * 200

for i in range (num_lines):
    x = random.randint (1, 132)
    # time.sleep (0.01)
    sys.stdout.flush ()
    ch = f'{i}'[-1]
    col = 30 + i % 8
    # print (f"{numbers[0:x]}")
    print (f"\x1b[{col}m{numbers[0:x]}\x1b[m")

print ("--------");
