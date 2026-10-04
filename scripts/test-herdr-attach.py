import os,tempfile,subprocess,time,json,select,pty,signal,fcntl,termios,struct
root=tempfile.mkdtemp(prefix='island-mouse-')
env=os.environ.copy(); env.update(HERDR_CONFIG_PATH=root+'/config.toml', XDG_CONFIG_HOME=root, HERDR_SOCKET_PATH=root+'/herdr.sock', HERDR_SESSION='island-mouse-test')
for k in ['HERDR_ENV','HERDR_PANE_ID','HERDR_TAB_ID','HERDR_WORKSPACE_ID']: env.pop(k,None)
open(root+'/config.toml','w').write('onboarding = false\n[terminal]\ndefault_shell = "/bin/sh"\nshell_mode = "non_login"\n')
cli=os.environ.get('HERDR_BIN_PATH',os.path.expanduser('~/.local/bin/herdr'))
server=subprocess.Popen([cli,'server'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def run(*args):
 p=subprocess.run([cli,*args],env=env,capture_output=True,text=True); p.check_returncode(); return json.loads(p.stdout) if p.stdout.strip() else None
pid=None
fd=None
try:
 for _ in range(100):
  if os.path.exists(env['HERDR_SOCKET_PATH']): break
  time.sleep(.1)
 data=run('workspace','create','--cwd',root,'--no-focus')
 pane=data['result']['root_pane']; target=pane['pane_id']; terminal=pane['terminal_id']
 # Enable application mouse tracking, SGR coordinates and an alternate screen.
 fixture=root+'/fixture.py'
 fixture_code = 'import sys,tty,os\ntty.setraw(0)\nsys.stdout.write("\\x1b[?1049h\\x1b[?1000h\\x1b[?1006h\\x1b[2J\\x1b[HMouse fixture")\nsys.stdout.flush()\nf=open('+repr(root+'/input.log')+',"ab",buffering=0)\nwhile True:\n b=os.read(0,4096); f.write(b)\n if b == b"o":\n  sys.stdout.write("\\x1b[?1000l\\x1b[?1006l");sys.stdout.flush()\n'
 open(fixture,'w').write(fixture_code)
 run('pane','run',target,'python3 '+fixture)
 time.sleep(.3)
 pid,fd=pty.fork()
 if pid==0:
  os.execve(cli,[cli,'terminal','attach',terminal],dict(env,TERM='xterm-256color'))
 fcntl.ioctl(fd,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
 time.sleep(.6)
 output=b''
 deadline=time.monotonic()+3
 while time.monotonic()<deadline and select.select([fd],[],[],.2)[0]: output+=os.read(fd,65536)
 assert b'\x1b[?1006h' in output, 'attach must advertise SGR mouse reporting'
 def send(raw): os.write(fd,raw);time.sleep(.3)
 send(b'\x1b[<0;5;3M\x1b[<0;5;3m\x1b[<64;5;3M')
 assert open(root+'/input.log','rb').read() == b'\x1b[<0;5;3M\x1b[<0;5;3m\x1b[<64;5;3M', 'click and wheel coordinates must reach the application'
 send(b'\x02\x02'); assert open(root+'/input.log','rb').read().endswith(b'\x02'), 'double prefix must deliver literal Ctrl+B'
 send(b'o')
 send(b'\x1b[<0;5;3M\x1b[<0;5;3m')
 assert open(root+'/input.log','rb').read().endswith(b'\x02o'), 'mouse-disabled application must not receive mouse bytes'
 os.kill(pid,signal.SIGKILL)
 os.waitpid(pid,0);os.close(fd);pid=None;fd=None
 # A fresh controller must be able to attach after the first exits.
 retry=subprocess.Popen([cli,'terminal','session','control',terminal],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  assert select.select([retry.stdout],[],[],3)[0], 'controller lease was not released'
  assert json.loads(retry.stdout.readline())['type']=='terminal.frame'
 finally:
  retry.kill();retry.wait()
 print('PASS interactive attach: click, wheel, literal prefix, disabled mouse, controller release')

finally:
 if pid is not None:
  try: os.kill(pid,signal.SIGKILL);os.waitpid(pid,0)
  except ProcessLookupError: pass
 if fd is not None: os.close(fd)
 subprocess.run([cli,'server','stop'],env=env,capture_output=True)
 server.wait(timeout=5)
 print('TEST_ROOT',root)
