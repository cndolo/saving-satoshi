# One process, a few threads: sufficient for a small course and the in-memory login throttle.
workers 0
threads 1, 4
bind ENV.fetch('BIND', 'tcp://127.0.0.1:8000')
