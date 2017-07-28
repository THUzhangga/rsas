import pandas as pd
import numpy as np
import math

datetime = pd.date_range('1990/1/1', periods=1000, freq='D')
datetime=pd.Series(datetime, name='datetime')
# datetime = datetime.to_frame(name='datetime')
timestep = pd.Series(i for i in range(1000))
timestep[0], timestep[999] = (0, 999)
# timestep = timestep.to_frame(name='timestep')
timestep.index = datetime

#J = pd.Series(3 for i in range(1000))
J = pd.Series(np.linspace(1, 6, 1000))
# J = J.to_frame(name='J')
J.index = datetime

#Q = pd.Series(3 for i in range(1000))
Q = pd.Series(np.linspace(1, 6, 1000))
# Q = Q.to_frame(name='Q')
Q.index = datetime

#C_J = pd.Series(0 for i in range(1000))
#C_J[9], C_J[399], C_J[799] = (100, 100, 100)
C_J = pd.Series(np.sin(i) + 1 for i in xrange(1000))

# C_J = C_J.to_frame(name='C_J')
C_J.index = datetime

ST_min = pd.Series(0 for i in xrange(1000))
# ST_min = ST_min.to_frame(name='ST_min')
ST_min.index = datetime
ST_max = pd.Series(210 for i in xrange(1000))
# ST_max = ST_max.to_frame(name='ST_max')
ST_max.index = datetime
df = pd.DataFrame({'timestep':timestep, 'J':J, 'Q':Q, 'C_J':C_J, 'ST_min':ST_min, 'ST_max':ST_max})
df.to_csv('jzm.csv')