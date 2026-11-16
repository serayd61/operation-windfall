import sys,subprocess,re,os
sys.path.insert(0,os.path.dirname(__file__))
from lines import V
v,l,url=sys.argv[1],int(sys.argv[2]),sys.argv[3]
lang=['','en','tr','de'][l]; src=f'{v}{l}.mp3'
subprocess.run(['curl','-s','-o',src,url],check=True)
out=subprocess.run(['ffmpeg','-hide_banner','-i',src,'-af','silencedetect=noise=-38dB:d=0.9','-f','null','-'],capture_output=True,text=True).stderr
dur=float(re.search(r'Duration: (\d+):(\d+):([\d.]+)',out).group(3))+60*float(re.search(r'Duration: (\d+):(\d+):([\d.]+)',out).group(2))
ss=[float(x) for x in re.findall(r'silence_start: ([\d.]+)',out)]; se=[float(x) for x in re.findall(r'silence_end: ([\d.]+)',out)]
segs=[]; t=0
for a,b in zip(ss,se):
    if a-t>0.15: segs.append((t,a))
    t=b
if dur-t>0.15: segs.append((t,dur))
L=V[v]; print(v,lang,'segments',len(segs),'lines',len(L))
if len(segs)!=len(L): print('MISMATCH',[(round(a,1),round(b,1)) for a,b in segs]); sys.exit(1)
od=sys.argv[4]+'/'+lang; os.makedirs(od,exist_ok=True)
for (a,b),x in zip(segs,L):
    a=max(0,a-.04); b=min(dur,b+.12)
    subprocess.run(['ffmpeg','-y','-loglevel','error','-ss',str(a),'-to',str(b),'-i',src,'-ac','1','-ar','22050','-af','loudnorm=I=-16:TP=-1.5:LRA=7,afade=t=out:st=%f:d=0.08'%(b-a-.08),'-b:a','40k',f'{od}/{x[0]}.mp3'],check=True)
    print(f'  {x[0]:9s} {b-a:4.1f}s  {x[l]}')
