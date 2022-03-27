## WaitAbortAcq
## writes A to ctrl waits to read S from resp
##
##RestartAcq
## writes G to crtl does not wait
##
##acqthread_recv_cmd
## waits to read any command from ctrl; returns Q on error
##
##acqthread_wait_for_ok
## writes s to resp; waits for G from ctrl; returns Q on error

import sys
import os
import numbers
import collections
import traceback
from threading import Thread
import time


import spatialnde2 as snde

from dataguzzler_python.dgpy import Module as dgpy_Module
from dataguzzler_python.dgpy import CurContext
from dataguzzler_python.dgpy import RunInContext
###from dataguzzler_python cimport dgold
###from dataguzzler_python cimport wfmstore
###from dataguzzler_python cimport dg_internal


from . import gc
#import pint # units library

from libc.stdio cimport fprintf,stderr

from libc.stdint cimport uint64_t
from libc.stdint cimport int64_t
from libc.stdint cimport int32_t
from libc.stdint cimport uint32_t
from libc.stdint cimport int16_t
from libc.stdint cimport uint16_t
from libc.stdint cimport int8_t
from libc.stdint cimport uintptr_t
from libc.stdint cimport uint8_t
from libc.errno cimport errno,EAGAIN,EINTR
from libc.stdlib cimport calloc,free
from libcpp cimport bool

IF UNAME_SYSNAME == "Windows":
    # On Windows, we can use the below defined pipe, read, and write functions 
    # identically to how they are used on Linux.  However, we need to use 
    # WaitForSingleObject/WaitForMultipleObjects instead of poll.
    cdef extern from "<Windows.h>" nogil:
        int INFINITE
        unsigned long WAIT_OBJECT_0
        ctypedef struct SECURITY_ATTRIBUTES:
            pass
        ctypedef SECURITY_ATTRIBUTES* LPSECURITY_ATTRIBUTES
        void* CreateEvent "CreateEventA" (LPSECURITY_ATTRIBUTES, int, int, const char*)
        unsigned long WaitForSingleObject(void*, unsigned long)
        unsigned long WaitForMultipleObjects(unsigned long, const void**, int, unsigned long) 
        unsigned long GetLastError()       
        bool SetEvent(void*)
    cdef extern from "<io.h>" nogil:
        int _pipe(int *, unsigned int, int )
        int read "_read" (int const, void * const, unsigned int const)
        int write "_write" (int , const void *, unsigned int)
    cdef inline int pipe(int *pfds) nogil:
        return _pipe(pfds, 65536, 0)
    ctypedef void* pollfd
ELSE:
    from posix.unistd cimport pipe,read,write
    cdef extern from "poll.h" nogil:
        struct pollfd:
            int fd
            short events
            short revents
            pass
        int poll(pollfd *fds, int nfds,int timeout)
        short POLLIN,POLLOUT
        pass

import numpy as np
cimport numpy as np

###from dataguzzler cimport dg_config

###from dataguzzler cimport linklist as dgl
###cimport dataguzzler as dg

cdef extern from "CsPrototypes.h" nogil:
    ctypedef int32_t int32
    ctypedef uint32_t uInt32
    ctypedef int16_t int16
    ctypedef char *LPSTR
    ctypedef uint32_t CSHANDLE
    ctypedef void * PCSSYSTEMINFO
    ctypedef struct IN_PARAMS_TRANSFERDATA:
        uint32_t u32Segment
        uint32_t u32Mode
        void *hNotifyEvent
        int64_t i64StartAddress
        int64_t i64Length
        uint16_t u16Channel
        void *pDataBuffer        
        pass
    ctypedef struct OUT_PARAMS_TRANSFERDATA:
        pass
    
    ctypedef IN_PARAMS_TRANSFERDATA * PIN_PARAMS_TRANSFERDATA
    ctypedef OUT_PARAMS_TRANSFERDATA * POUT_PARAMS_TRANSFERDATA
    
    int32 CsInitialize()
    int32 CsGetSystem(CSHANDLE* phSystem, uInt32 u32BoardType, uInt32 u32Channels, uInt32 u32SampleBits, int16 i16Index )
    int32 CsFreeSystem(CSHANDLE)
    int32 CsGet(CSHANDLE hSystem, int32 nIndex, int32 nConfig, void* pData)
    int32 CsSet(CSHANDLE hSystem, int32 nIndex, const void* const pData)
    int32 CsGetSystemInfo(CSHANDLE hSystem, PCSSYSTEMINFO pSystemInfo)
    int32 CsGetSystemCaps(CSHANDLE hSystem, uInt32 CapsId, void* pBuffer, uInt32* BufferSize)
    int32 CsDo(CSHANDLE hSystem, int16 i16Operation)

    int32 CsTransfer(CSHANDLE hSystem, PIN_PARAMS_TRANSFERDATA pInData, POUT_PARAMS_TRANSFERDATA outData)
    #int32 CsTransferEx(CSHANDLE hSystem, PIN_PARAMS_TRANSFERDATA_EX pInData, POUT_PARAMS_TRANSFERDATA_EX outData)
    int32 CsGetEventHandle(CSHANDLE hSystem, uInt32 u32EventType, void* phEvent) # note: phEvent is EVENT_HANDLE on win32 and int on Linux
    int32 CsGetStatus(CSHANDLE hSystem)
    int32 CsGetErrorStringA(int32 i32ErrorCode, LPSTR lpBuffer, int nBufferMax)

    #int16 ACTION_ABORT
    ctypedef char TCHAR
    pass

cdef double CS_GAIN_2_V=gc.CS_GAIN_2_V

# AcquisitionConfig data structure
CSACQUISITIONCONFIG = np.dtype([
    ("Size",np.uint32),
    ("SampleRate",np.int64),
    ("ExtClk",np.uint32),
    ("ExtClkSampleSkip",np.uint32),
    ("Mode",np.uint32),
    ("SampleBits",np.uint32),
    ("SampleRes",np.int32),
    ("SampleSize",np.uint32),
    ("SegmentCount",np.uint32),
    ("Depth",np.int64),
    ("SegmentSize",np.int64),
    ("TriggerTimeout",np.int64), # timeout in 100ns units
    ("TrigEnginesEn",np.uint32),
    ("TriggerDelay",np.int64),
    ("TriggerHoldoff",np.int64),
    ("SampleOffset",np.int32),
    ("TimeStampConfig",np.uint32),
    ("SegmentCountHigh",np.int32)],align=True)

CSCHANNELCONFIG = np.dtype([
    ("Size",np.uint32),
    ("ChannelIndex",np.uint32),
    ("Term",np.uint32),
    ("InputRange",np.uint32),
    ("Impedance",np.uint32),
    ("Filter",np.uint32),
    ("DcOffset",np.int32),
    ("Calib",np.int32)],align=True)

CSTRIGGERCONFIG = np.dtype([
    ("Size",np.uint32),
    ("TriggerIndex",np.uint32),
    ("Condition",np.uint32),
    ("Level",np.int32),
    ("Source",np.int32),
    ("ExtCoupling",np.uint32),
    ("ExtTriggerRange",np.uint32),
    ("ExtImpedance",np.uint32),
    ("Value1",np.int32),
    ("Value2",np.int32),
    ("Filter",np.uint32),
    ("Relation", np.uint32)],align=True)




# Data types for CsGetSystemCaps(): Note that only
# a few of these are defined, but you can add more if needed!

CSSAMPLERATETABLE = np.dtype([ ("SampleRate",np.int64),
                               ("strText",'a32')],align=True)
CSRANGETABLE = np.dtype([("InputRange",np.uint32),
                         ("strText",'a32'),
                         ("Reserved",np.uint32)],align=True)
CSIMPEDANCETABLE = np.dtype([("Impedance",np.uint32),
                             ("strText",'a32'),
                             ("Reserved",np.uint32)],align=True)


syscaps_type_map = {
    # You can add the rest of these if needed...
    gc.CAPS_SAMPLE_RATES: CSSAMPLERATETABLE,
    gc.CAPS_INPUT_RANGES: CSRANGETABLE,
    gc.CAPS_IMPEDANCES: CSIMPEDANCETABLE,
}

class CSError(Exception):
    def __init__(self,contextstr,errcode=None):
        cdef int bufsz=10000
        cdef np.ndarray[np.int8_t,mode='c'] buf
        if errcode is not None:
            buf=np.zeros(bufsz,dtype=np.int8)
            err=CsGetErrorStringA(errcode,buf.data,bufsz)
            if err > 0:
                # Got an error string
                buflen=(~buf.astype(np.bool)).nonzero()[0][0]
                errcodestr=buf[:buflen].tostring().decode('utf-8')
                pass
            else: 
                errcodestr="Error #%d " % (errcode)
                pass
            contextstr="%s: %s" % (contextstr,errcodestr)
            
            pass
        super(CSError,self).__init__("CompuScope error: %s" % (contextstr))
        pass
    pass

cdef class CSLowLevel:
    # Single-threaded and non-reentrant
    cdef CSHANDLE System
    cdef int InTransaction

    cdef public object recdb

    # System hardware information
    cdef public object SysInfo

    # ParamDict from cs.py
    cdef public object ParamDict
 
    cdef public object ARRAY_TRIGGERCONFIG # numpy dtype
    cdef public object ARRAY_CHANNELCONFIG # numpy dtype
    
    # These variables may be None or contain the latest
    # cached knowledge of the configuration    
    cdef public object AcquisitionConfig # CSACQUISITIONCONFIG
    cdef public object ChannelConfig   # ARRAY_CHANNELCONFIG
    cdef public object TriggerConfig  # ARRAY_TRIGGERCONFIG

    cdef public object selfptr
    
    # These variables only valid during a (config) transction 
    cdef public np.ndarray AcquisitionConfig_modified  # CSACQUISITIONCONFIG
    cdef public np.ndarray ChannelConfig_modified    # ARRAY_CHANNELCONFIG
    cdef public np.ndarray TriggerConfig_modified   # ARRAY_TRIGGERCONFIG

    # For acquisition thread
    cdef public object AcquisitionThread

    cdef public object result_channel_ptrs

    cdef public object module_name
    
    cdef int pipe_fd_acqctrl[2]
    cdef int pipe_fd_acqresp[2]

    IF UNAME_SYSNAME == "Windows":
        cdef void* fd_triggered_read
        cdef void* fd_end_acq_read
        cdef void* hEventWorkerInterrupted  # Tell Worker To Check Messages
        cdef void* hEventWorkerDone         # Worker Reply To Confirm Receipt
    ELSE:
        cdef int fd_triggered_read
        cdef int fd_end_acq_read

    # Variables used by acquisition thread
    # ***!!! MAY ONLY BE MODIFIED WHILE ACQUISITION THREAD IS PAUSED
    # Consider these as locked by the GIL -- only modified/accessed
    # while GIL is held
    ###cdef wfmstore.Channel **Channel
    cdef void **CurChanDataPtrs # Array of target waveforms for acquisition thread -- valid only while acquiring
    cdef int64_t PreTriggerSamples
    cdef int64_t Length
    cdef int64_t StartAddress
    cdef void **RawBuffers # Array of buffer pointers
    cdef int32_t ChannelCount # Total number of available channels
    cdef int32_t ChannelIncrement # Step size between channels
    cdef uint32_t *InputRange
    cdef uint32_t SampleSize
    cdef uint32_t SampleRate
    cdef int32_t SampleOffsetInQuantSteps # i32SampleOffset... Should be corresponding to the top of the detectable voltage range
    cdef int32_t SampleResolution # Number of quantization in positive half of measurement range.... i.e. 10 bits -> 1024 steps total -> SampleResolution = 512 steps
    cdef int32_t *DcOffset # Array of dc offsets in mV
    cdef double *ProbeAtten
    cdef int64_t lastglobalrev
    
    
    def __init__(self,module_name,recdb,selfptr,ParamDict,uint32_t boardtype,uint32_t numchannels,uint32_t samplebits,int16_t index):
        """ parameters boardtype (e.g. gagecontstants.CSXXXX_BOARDTYPE), numchannels, samplebits, and index used solely (per CsGetSystem() documentation) the
        board or boards to be initialized. These parameters may 
        be given as zero to represent "don't care". C"""
        self.module_name=module_name
        self.recdb=recdb
        self.result_channel_ptrs = collections.OrderedDict()
        self.ParamDict=ParamDict
        self.SysInfo=None
        self.AcquisitionConfig=None
        self.ChannelConfig=None
        self.TriggerConfig=None
        self.AcquisitionThread=None
        self.selfptr = selfptr

        #("Calling CsInitialize()\n")
        #sys.stderr.flush()
        err=CsInitialize()
        #sys.stderr.write("Called CsInitialize()\n")
        #sys.stderr.flush()
        if err < 0:
            raise CSError("CsInitialize()",err)
        
        err=CsGetSystem(&self.System,boardtype,numchannels,samplebits,index)
        if err < 0:
            raise CSError("CsGetSystem()",err)

        self.RawBuffers=NULL
        self.InTransaction=0
        self.ChannelCount=0
        self.ChannelIncrement=1
        self.Length=0
        self.SysInfo=self.GetSystemInfo()
        self.ARRAY_TRIGGERCONFIG=np.dtype([ ("TriggerCount",np.uint32),
                                            ("Trigger",CSTRIGGERCONFIG,self.SysInfo[0]["TriggerMachinesCount"])],align=True)
        self.ARRAY_CHANNELCONFIG=np.dtype([ ("ChannelCount",np.uint32),
                                            ("Channel",CSCHANNELCONFIG,self.SysInfo[0]["ChannelCount"])],align=True)

        IF UNAME_SYSNAME == "Windows":
            if pipe(self.pipe_fd_acqctrl) != 0:
                raise IOError("pipe()")

            if pipe(self.pipe_fd_acqresp) != 0:
                raise IOError("pipe()")
        ELSE:
            if pipe(self.pipe_fd_acqctrl) != 0:
                raise IOError("pipe()")

            if pipe(self.pipe_fd_acqresp) != 0:
                raise IOError("pipe()")

        err=CsGetEventHandle(self.System,gc.ACQ_EVENT_TRIGGERED,&self.fd_triggered_read);
        if err < 0:
            raise CSError("CsGetEventHandle()",err)

        err=CsGetEventHandle(self.System,gc.ACQ_EVENT_END_BUSY,&self.fd_end_acq_read);
        if err < 0:
            raise CSError("CsGetEventHandle()",err)

        IF UNAME_SYSNAME == "Windows":
            self.hEventWorkerInterrupted = CreateEvent(NULL, False, False, NULL)
            self.hEventWorkerDone = CreateEvent(NULL, False, False, NULL)


        pass

    def StartAcqThread(self):
        self.RestartAcq()  # Set up parameters
        # Set acquisition thread going
        self.AcquisitionThread = Thread(target=self.AcquisitionThreadCode,daemon=True)
        self.AcquisitionThread.start()
        #sys.stderr.write("AcquisitionThread started\n")
        #sys.stderr.flush()

        # Start data acquisition
        err=CsDo(self.System,gc.ACTION_START)
        if err < 0:
            raise CSError("CsDo(ACTION_START)",err)
            

        pass
    
    cdef void ConvertChannelToVoltage(self,void *RawBuffer, void *Target, int32_t ChannelIndex,uint32_t SampleSize,uint32_t InputRange, int32_t SampleOffsetInQuantSteps,int32_t SampleResolution,int32_t DcOffset,int64_t Length) nogil:
        # Called only in acquisition thread
        cdef uint8_t *Buf1
        cdef uint16_t *Buf2
        cdef uint32_t *Buf4
        cdef int64_t SampleCnt
        cdef double ScaleFactor
        ScaleFactor=(<double>InputRange)/<double>CS_GAIN_2_V
        cdef double *output = <double*>Target
        
        if SampleSize==1:
            Buf1=<uint8_t *>RawBuffer
            for SampleCnt in range(Length):
                output[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf1[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass

        if SampleSize==2:
            Buf2=<uint16_t *>RawBuffer
            for SampleCnt in range(Length):
                output[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf2[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass

        if SampleSize==4:
            Buf4=<uint32_t *>RawBuffer
            for SampleCnt in range(Length):
                output[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf4[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass
        
        pass
    
    def WaitAbortAcq(self):
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        IF UNAME_SYSNAME == "Windows":
            cdef unsigned long dwWaitRet = 0

        if self.AcquisitionThread is None or not self.AcquisitionThread.is_alive():
            return


        # Write 'A' for abort
        #sys.stderr.write("Writing 'A'\n")
        #sys.stderr.flush()
        ctrlbyte='A'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqctrl[1],&ctrlbyte,1)
            err=errno
            pass
        
        IF UNAME_SYSNAME == "Windows":
            if SetEvent(self.hEventWorkerInterrupted) == 0:
                raise Exception('Failed to Send Event Siganl %#010x\n' % GetLastError())

        # Wait for response of 'S' for stopped
        #sys.stderr.write("Waiting for 'S'\n")
        #sys.stderr.flush()

        IF UNAME_SYSNAME == "Windows":
            while WaitForSingleObject(self.hEventWorkerDone, 0) != WAIT_OBJECT_0:
                # THIS MUST BE HERE OR WE WILL GET STUCK BECAUSE PYTHON IS BEING BLOCKED
                time.sleep(0.1)
            #sys.stderr.write("Got Event Back\n")
            #sys.stderr.flush()

        # Start data acquisition
        #sys.stderr.write("Getting ready to abort\n")
        #sys.stderr.flush()
        err=CsDo(self.System,gc.ACTION_ABORT)
        if err < 0:
            raise CSError("CsDo(ACTION_ABORT)",err)

        #sys.stderr.write("Aborted\n")
        #sys.stderr.flush()

        while ctrlbyte != 'S': 
            #sys.stderr.write('Loop\n')
            #sys.stderr.flush()
            err=EAGAIN
            while err==EAGAIN or err==EINTR:
                nbytes=read(self.pipe_fd_acqresp[0],&ctrlbyte,1)
                err=errno
                pass
            if nbytes != 1:
                raise IOError("WaitAbortAcq")
            pass
        return ctrlbyte
    
    def RestartAcq(self):
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        # Set up acquisition variables
        OldAcqChannels=self.ChannelCount//self.ChannelIncrement
        OldLength=self.Length
        OldLengthBytes=self.SampleSize*self.Length

        
        ChannelsPerBoard = self.SysInfo[0]["ChannelCount"]//self.SysInfo[0]["BoardCount"]
        MaskedMode = self.GetAcquisitionParamRaw("Mode") & gc.CS_MASKED_MODE
        self.ChannelCount = self.SysInfo[0]["ChannelCount"]
        self.ChannelIncrement = ChannelsPerBoard//MaskedMode
        if self.ChannelIncrement==0:
            self.ChannelIncrement=1
            pass
        

        NumAcqChannels=self.ChannelCount//self.ChannelIncrement

        if (self.CurChanDataPtrs != NULL and NumAcqChannels != OldAcqChannels) or not(self.CurChanDataPtrs):
            if self.CurChanDataPtrs:
                free(self.CurChanDataPtrs)
                pass
            self.CurChanDataPtrs=<void **>calloc(sizeof(void *)*(self.ChannelCount//self.ChannelIncrement),1)
            pass


        ####### TODO:  There currently doesn't appear to be a mechanism from Python to delete channels
        #######        We'll ignore this for now and hope nobody tries to disable channels
        if len(self.result_channel_ptrs) > NumAcqChannels:
            raise Exception("Removal of channels presently not supported -- please kill Dataguzzler first")

        transact = self.recdb.start_transaction()
        try:
            while len(self.result_channel_ptrs) < NumAcqChannels:
                channame = ("/%s/CH%d" % (self.module_name, len(self.result_channel_ptrs) + 1))
                #sys.stderr.write('Creating Channel %s' % (channame))
                #sys.stderr.flush()
                self.result_channel_ptrs[channame] = self.recdb.define_channel(str(channame), "main", self.recdb.raw())
        except:
            raise
        finally:
            transact.end_transaction()

        #dgold.dg_enter_main_context()
        #try:
        #my_id=str(id(self)).encode('utf-8')
        #if (self.Channel != NULL and NumAcqChannels != OldAcqChannels) or not(self.Channel):
        #    if self.Channel:
        #        for cnt in range(OldAcqChannels):
        #            wfmstore.DeleteChannel(self.Channel[cnt],my_id)
        #            pass
        #        free(self.Channel)
        #        pass
        #    self.Channel=<wfmstore.Channel **>calloc(sizeof(wfmstore.Channel *)*NumAcqChannels,1)
        #
        #    for cnt in range(NumAcqChannels):
        #        ChanName=("CH%d" % (cnt+1)).encode('utf-8')
        #        self.Channel[cnt]=wfmstore.CreateChannel(ChanName,my_id,0,NULL,0)
        #        pass
        #    pass
        #pass
        #except:
        #    raise
        #finally:
        #    dgold.dg_leave_main_context()
        #    pass

        
        self.PreTriggerSamples = self.GetAcquisitionParamRaw("TriggerHoldoff")
        self.Length=self.GetAcquisitionParamRaw("Depth")

        self.SampleSize = self.GetAcquisitionParamRaw("SampleSize")
        self.SampleRate = self.GetAcquisitionParamRaw("SampleRate")

            
        # Not sure I understand the start address calculation... it's not in the docs. This is based on the minimum start address formula from Events.c
        self.StartAddress = self.GetAcquisitionParamRaw("TriggerDelay") + self.Length - self.GetAcquisitionParamRaw("SegmentSize")
        
        if self.Length > self.GetAcquisitionParamRaw("SegmentSize"):
            sys.stderr.write("CompuScope: Depth larger than SegmentSize")
            self.Length = self.GetAcquisitionParamRaw("SegmentSize")
            pass

        if (self.RawBuffers != NULL and NumAcqChannels != OldAcqChannels) or not (self.RawBuffers):
            if self.RawBuffers:
                free(self.RawBuffers)
                pass
            
            self.RawBuffers=<void **>calloc(sizeof(void *)*(self.ChannelCount//self.ChannelIncrement),1)
            pass
        
        LengthBytes=self.SampleSize*self.Length
        
        for Cnt in range(self.ChannelCount//self.ChannelIncrement):
            if (self.RawBuffers[Cnt] and LengthBytes <= OldLengthBytes) or not (self.RawBuffers[Cnt]):
                if self.RawBuffers[Cnt]:
                    free(self.RawBuffers[Cnt])
                    pass
                
                self.RawBuffers[Cnt]=calloc(LengthBytes,1)
                pass
            pass

        if (self.InputRange != NULL and NumAcqChannels != OldAcqChannels) or not (self.InputRange):
            if self.InputRange:
                free(self.InputRange)
                pass
            
            self.InputRange=<uint32_t *>calloc(sizeof(uint32_t)*NumAcqChannels,1)
            pass
        
        for Cnt in range(NumAcqChannels):
            self.InputRange[Cnt]=self.GetChanParamRaw("ChanInputRange",Cnt*self.ChannelIncrement)
            pass
        self.SampleOffsetInQuantSteps=self.GetAcquisitionParamRaw("SampleOffset")

        self.SampleResolution=self.SysInfo[0]["SampleResolution"]

        if (self.DcOffset != NULL and NumAcqChannels != OldAcqChannels) or not (self.DcOffset):
            if self.DcOffset:
                free(self.DcOffset)
                pass
            
            self.DcOffset=<int32_t *>calloc(sizeof(int32_t)*NumAcqChannels,1)
            pass
        
        for Cnt in range(NumAcqChannels):
            self.DcOffset[Cnt]=self.GetChanParamRaw("ChanDcOffset",Cnt*self.ChannelIncrement)
            pass

        # ProbeAtten should be configured as a property of the
        # main CompuScope class... but for now treat it as 1.0
        if (self.ProbeAtten != NULL and NumAcqChannels != OldAcqChannels) or not (self.ProbeAtten):
            if self.ProbeAtten:
                free(self.ProbeAtten)
                pass
            
            self.ProbeAtten=<double *>calloc(sizeof(double)*NumAcqChannels,1)
            for cnt in range(NumAcqChannels):
                self.ProbeAtten[cnt]=1.0
                pass
            pass
        
        
        if self.AcquisitionThread is None:
            return
        # Signal AcquisitionThread it is OK to keep going

        # Start data acquisition
        err=CsDo(self.System,gc.ACTION_START)
        if err < 0:
            raise CSError("CsDo(ACTION_START)",err)

        # Write 'G' for Go
        ctrlbyte='G'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqctrl[1],&ctrlbyte,1)
            err=errno
            pass

        IF UNAME_SYSNAME == "Windows":
            if SetEvent(self.hEventWorkerInterrupted) == 0:
                raise Exception('Failed to Send Siganl to Worker %#010x\n' % GetLastError())

        pass
    
    cdef char acqthread_recv_cmd(self) nogil:
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        #fprintf(stderr,"acqthread_recv_cmd()\n");
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=read(self.pipe_fd_acqctrl[0],&ctrlbyte,1)
            if nbytes < 0:
                err=errno
                pass
            else: 
                err=0
                pass
            pass
        #fprintf(stderr,"acqthread_recv_cmd() err=%d nbytes=%d returning %d\n",<int>err,<int>nbytes,<int>ctrlbyte);
        err=EAGAIN
        if nbytes != 1:
            # Treat error or EOF as quit command
            return 'Q'
        return ctrlbyte
    
    cdef char acqthread_wait_for_ok(self) nogil:
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        IF UNAME_SYSNAME == "Windows":
            cdef unsigned long dwWaitRet = 0            

        #fprintf(stderr,"acqthread_wait_for_ok()\n")

        # Write 'S' for stopped
        ctrlbyte='S'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqresp[1],&ctrlbyte,1)
            if nbytes < 0:
                err=errno
                pass
            else:
                err=0
                pass

            pass

        IF UNAME_SYSNAME == "Windows":
            if SetEvent(self.hEventWorkerDone) == 0:
                raise Exception('Worker Failed to Send Done Siganl %#010x\n' % GetLastError())

        #fprintf(stderr,"Waiting for 'G'\n")

        IF UNAME_SYSNAME == "Windows":
            while WaitForSingleObject(self.hEventWorkerInterrupted, 0) != WAIT_OBJECT_0:
                pass
            #fprintf(stderr, "Got Event Back\n")

        # Wait for response of 'G'
        while ctrlbyte != 'G': # G for go
            err=EAGAIN
            while err==EAGAIN or err==EINTR:
                nbytes=read(self.pipe_fd_acqctrl[0],&ctrlbyte,1)
                if nbytes < 0:
                    err=errno
                    pass
                else:
                    err=0
                    pass
                pass
            if nbytes != 1:
                # Treat error or EOF as quit command
                return 'Q'
            pass
        #fprintf(stderr,"acqthread_wait_for_ok() done.\n")

        return ctrlbyte
    
    def AcquisitionThreadCode(self):
        cdef int16_t ACTION_START=gc.ACTION_START
        cdef int16_t ACTION_ABORT=gc.ACTION_ABORT
        cdef int Quit=0
        cdef int32_t err=0
        cdef char *errmsg=""
        cdef pollfd pollfds[3]
        cdef char acqcmd
        cdef int32_t ChannelIndex
        cdef size_t dimlen

        cdef ssize_t rderr

        cdef int polleval = 0
        cdef unsigned long dwWaitRet = 0

        ###cdef wfmstore.Wfm **Target
        cdef int64_t PreTriggerSamples
        cdef int64_t Length
        cdef int64_t StartAddress
        cdef void **RawBuffers
        cdef int32_t ChannelCount=self.ChannelCount
        cdef int32_t ChannelIncrement=self.ChannelIncrement
        cdef uint32_t *InputRange
        cdef int32_t SampleOffsetInQuantSteps
        cdef int32_t SampleResolution
        cdef int32_t *DcOffset
        cdef int32_t SampleSize
        cdef double *ProbeAtten

        cdef int nbytes
        cdef char rd_sink

        cdef int32_t NumAcqChannels=ChannelCount//ChannelIncrement
        
        cdef IN_PARAMS_TRANSFERDATA InParams
        cdef OUT_PARAMS_TRANSFERDATA OutParams
        
        #sys.stderr.write("AcquisitionThread: start\n")
        #sys.stderr.flush()

        IF UNAME_SYSNAME == "Windows":
            pollfds[0] = self.fd_end_acq_read
            pollfds[1] = self.hEventWorkerInterrupted
            #pollfds[2] = 
        ELSE:
            pollfds[0].fd = self.fd_end_acq_read
            pollfds[1].fd = self.pipe_fd_acqctrl[0]
            #pollfds[2].fd = self.fd_triggered_read
            
            pollfds[0].events=POLLIN
            pollfds[1].events=POLLIN
            #pollfds[2].events=POLLIN

        InParams.u32Segment=1
        InParams.u32Mode=gc.TxMODE_DATA_ANALOGONLY # equivalent to TxMODE_DEFAULT
        InParams.hNotifyEvent=NULL
        
        err=0
        
        while not Quit:
            #sys.stderr.write("AcquisitionThread: Loop start\n")
            #sys.stderr.flush()
            # Error handling is at beginning of loop so we can use
            # continue directive to break out into error handling
            if err < 0:
                try: 
                    raise CSError(errmsg,err)
                except:
                    traceback.print_exc(file=sys.stderr)
                    pass
                pass
            err=0
            errmsg=""

            #sys.stderr.write('1\n')
            #sys.stderr.flush()

            InParams.i64StartAddress=self.StartAddress
            InParams.i64Length=self.Length
            
            # Make local copy of raw buffer data pointers
            CurChanDataPtrs=self.CurChanDataPtrs
            PreTriggerSamples=self.PreTriggerSamples
            Length=self.Length
            StartAddress=self.StartAddress
            RawBuffers=self.RawBuffers
            InputRange=self.InputRange
            SampleOffsetInQuantSteps=self.SampleOffsetInQuantSteps
            SampleResolution=self.SampleResolution
            DcOffset=self.DcOffset
            SampleSize=self.SampleSize
            ProbeAtten=self.ProbeAtten
        
            #sys.stderr.write('2\n')
            #sys.stderr.flush()
            # Create Entry
            recptrs = []
            transact = self.recdb.start_transaction()
            #sys.stderr.write('3\n')
            #sys.stderr.flush()
            try:
                for name, ptr in self.result_channel_ptrs.items():
                    #sys.stderr.write('4\n')
                    #sys.stderr.flush()
                    recptr = snde.create_recording_ref(self.recdb, ptr, self.recdb.raw(), snde.SNDE_RTN_FLOAT64)
                    recptr.allocate_storage([Length], False)
                    recptrs.append(recptr)
                    pass                                
                pass
            except:
                raise
            finally:
                #sys.stderr.write('5\n')
                #sys.stderr.flush()
                globalrev = transact.end_transaction()
            
            for ChannelIndex in range(self.ChannelCount//self.ChannelIncrement):
                #sys.stderr.write('6\n')
                #sys.stderr.flush()
                CurChanDataPtrs[ChannelIndex] = <void*>(<uintptr_t>recptrs[ChannelIndex].void_shifted_arrayptr())
                pass

            
            with nogil:
                ## Start data acquisition
                #err=CsDo(self.System,ACTION_START)
                #if err < 0:
                #    errmsg="CsDo(ACTION_START)"
                #    continue # Break out and report error 
                #fprintf(stderr,'7\n')
                IF UNAME_SYSNAME == "Windows":
                    # NOTE: For win32 need to use WaitForSingleObject... See Gage Evetns.c/Threads.c example
                    dwWaitRet = WaitForMultipleObjects(2, pollfds, False, INFINITE)
                    polleval = dwWaitRet == WAIT_OBJECT_0+1
                ELSE:
                    pollfds[0].revents=0
                    pollfds[1].revents=0
                    #pollfds[2].revents=0
                    poll(pollfds,2,-1)
                    polleval = pollfds[1].revents & POLLIN                    

                #fprintf(stderr, 'WaitForMultipleObjects: %#010x\n', dwWaitRet)
                #fprintf(stderr, 'Error:  %#010x\n', GetLastError())
                #fprintf(stderr,'8\n')
                if polleval:
                    acqcmd=self.acqthread_recv_cmd()
                    #fprintf(stderr, "Made it back3\n")
                    if acqcmd=='A': # abort
                        #fprintf(stderr, "Aborting\n")
                        #err=CsDo(self.System,ACTION_ABORT)
                        #if err < 0:
                        #    errmsg="A CsDo(ACTION_ABORT)"
                        #    continue # Break out and report error 
                        with gil:
                            for recptr in recptrs:
                                recptr.rec.metadata = snde.immutable_metadata()
                                recptr.rec.mark_metadata_done()
                                recptr.rec.mark_as_ready()
                        self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                        continue
                    if acqcmd=='Q': # quit
                        #fprintf(stderr, "Quitting\n")
                        #err=CsDo(self.System,ACTION_ABORT)
                        #if err < 0:
                        #    errmsg="Q CsDo(ACTION_ABORT)"
                        #    continue # Break out and report error 
                        with gil:
                            for recptr in recptrs:
                                recptr.rec.metadata = snde.immutable_metadata()
                                recptr.rec.mark_metadata_done()
                                recptr.rec.mark_as_ready()
                        Quit=1
                        continue
                    pass

                #fprintf(stderr,'9\n')
                IF UNAME_SYSNAME == "Windows":
                    polleval = dwWaitRet == WAIT_OBJECT_0
                ELSE:
                    polleval = pollfds[0].revents & POLLIN

                if not(polleval):
                    err=1
                    errmsg="Poll returned without end_of_acquisition"
                    with gil:
                        for recptr in recptrs:
                            recptr.rec.metadata = snde.immutable_metadata()
                            recptr.rec.mark_metadata_done()
                            recptr.rec.mark_as_ready()
                    continue

                #fprintf(stderr,'10\n')
                # read byte indicating termination of acquisition
                IF not UNAME_SYSNAME == "Windows":
                    rderr=EAGAIN
                    while rderr==EAGAIN or rderr==EINTR:
                        nbytes=read(self.fd_end_acq_read,&rd_sink,1);
                        if nbytes < 0:
                            rderr=errno
                            pass
                        else:
                            rderr=0
                            pass
                        pass
                    
                #fprintf(stderr,'11\n')
                for ChannelIndex in range(NumAcqChannels): #range(1,self.ChannelCount+1,self.ChannelIncrement):
                    if err != 0:
                        continue  # raise any abort
                    
                    # Check for abort
                    #fprintf(stderr,'12\n')

                    IF UNAME_SYSNAME == "Windows":
                        # NOTE: For win32 need to use WaitForSingleObject... See Gage Evetns.c/Threads.c example
                        dwWaitRet = WaitForSingleObject(pollfds[1], 0)
                        polleval = dwWaitRet == WAIT_OBJECT_0
                    ELSE:
                        poll(pollfds,1,0)
                        polleval = pollfds[1].revents & POLLIN    


                    if polleval:
                        acqcmd=self.acqthread_recv_cmd()
                        #fprintf(stderr, "Made it back2\n")
                        if acqcmd=='A': # abort
                            #fprintf(stderr, "Aborting\n")
                            #err=CsDo(self.System,ACTION_ABORT)
                            #if err < 0:
                            #    errmsg="CSTransfer A CsDo(ACTION_ABORT)"
                            #    continue # Break out and report error 
                            with gil:
                                for recptr in recptrs:
                                    recptr.rec.metadata = snde.immutable_metadata()
                                    recptr.rec.mark_metadata_done()
                                    recptr.rec.mark_as_ready()
                            self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                            continue
                        if acqcmd=='Q': # quit
                            #fprintf(stderr, "Quitting\n")
                            #err=CsDo(self.System,ACTION_ABORT)
                            #if err < 0:
                            #    errmsg="CSTransfer Q CsDo(ACTION_ABORT)"
                            #    continue # Break out and report error 
                            with gil:
                                for recptr in recptrs:
                                    recptr.rec.metadata = snde.immutable_metadata()
                                    recptr.rec.mark_metadata_done()
                                    recptr.rec.mark_as_ready()
                            Quit=1
                            continue
                        pass
                    #fprintf(stderr,'13\n')
                    InParams.u16Channel=1+ChannelIndex*ChannelIncrement
                    InParams.pDataBuffer=RawBuffers[ChannelIndex]
                    err=CsTransfer(self.System,&InParams,&OutParams)
                    if err < 0:
                        errmsg="CSTransfer"
                        with gil:
                            for recptr in recptrs:
                                recptr.rec.metadata = snde.immutable_metadata()
                                recptr.rec.mark_metadata_done()
                                recptr.rec.mark_as_ready()
                        continue # Break out and report error 
                    
                    pass

                    #fprintf(stderr,'14\n')

                #dgold.dg_enter_main_context_c()

                ### TODO:  Save actual data
                ###wfmstore.StartTransaction()
                ###wfmstore.EndTransaction()
                
                # !!!*** From hereon in case of abort need to NotifyChannel() and
                # WfmUnfererence the Wfms   using self.acqthread_flushwfms(valid_data)   !!!****
                #dgold.dg_leave_main_context_c()

                # Now do the conversions
                #fprintf(stderr,'15\n')
                for ChannelIndex in range(ChannelCount//ChannelIncrement):
                    # Check for abort
                    IF UNAME_SYSNAME == "Windows":
                        # NOTE: For win32 need to use WaitForSingleObject... See Gage Evetns.c/Threads.c example
                        dwWaitRet = WaitForSingleObject(pollfds[1], 0)
                        polleval = dwWaitRet == WAIT_OBJECT_0
                    ELSE:
                        poll(pollfds,1,0)
                        polleval = pollfds[1].revents & POLLIN   
                    if polleval:
                        acqcmd=self.acqthread_recv_cmd()
                        #fprintf(stderr, "Made it back1\n")
                        if acqcmd=='A': # abort
                            #fprintf(stderr, "Aborting\n")
                            #err=CsDo(self.System,ACTION_ABORT)
                            ###with gil:
                            ###    self.acqthread_flushwfms(False)
                            ###    pass
                            #if err < 0:
                            #    errmsg="Conversion A CsDo(ACTION_ABORT)"
                            #    continue # Break out and report error 
                            with gil:
                                for recptr in recptrs:
                                    recptr.rec.metadata = snde.immutable_metadata()
                                    recptr.rec.mark_metadata_done()
                                    recptr.rec.mark_as_ready()
                            self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                            continue
                        if acqcmd=='Q': # quit
                            #fprintf(stderr, "Quitting\n")
                            #err=CsDo(self.System,ACTION_ABORT)
                            ###with gil:
                            ###    self.acqthread_flushwfms(False)
                            ###    pass
                            #if err < 0:
                            #    errmsg="Conversion Q CsDo(ACTION_ABORT)"
                            #    continue # Break out and report error 
                            with gil:
                                for recptr in recptrs:
                                    recptr.rec.metadata = snde.immutable_metadata()
                                    recptr.rec.mark_metadata_done()
                                    recptr.rec.mark_as_ready()
                            Quit=1
                            continue
                        pass
                    #fprintf(stderr,'16\n')
                    #### TODO: Correct to use actual data
                    self.ConvertChannelToVoltage(RawBuffers[ChannelIndex],CurChanDataPtrs[ChannelIndex],ChannelIndex,SampleSize,InputRange[ChannelIndex],SampleOffsetInQuantSteps,SampleResolution,DcOffset[ChannelIndex],Length)
                    pass

                pass

            # (if we wanted to be ambitious here, we could spawn this
            # next stuff off as a separate thread and start acquiring
            # the next data now)
            
            # Now get metadata ***!!!! (NEED TO IMPLEMENT)

            # ...
            #sys.stderr.write('17\n')
            #sys.stderr.flush()
            #### TODO -- Replace this with new metadata stuff
            for recptr in recptrs:
                recptr.rec.metadata = snde.immutable_metadata()
                recptr.rec.mark_metadata_done()
                recptr.rec.mark_as_ready()
                #sys.stderr.write('18\n')
                #sys.stderr.flush()
            #for ChannelIndex in range(ChannelCount//ChannelIncrement):
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumInt("Channel",1+ChannelIndex*(ChannelCount//ChannelIncrement)))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("ProbeAtten",self.ProbeAtten[ChannelIndex]))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("MaxLevel",(<double>self.InputRange[ChannelIndex])/2000.0))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("MinLevel",-(<double>self.InputRange[ChannelIndex])/2000.0))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("AmplUnits","Volts"))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("AmplCoord","Voltage"))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Coord1","Time"))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Units1","seconds"))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("IniVal1",-self.PreTriggerSamples*1.0/self.SampleRate))
            #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("Step1",1.0/self.SampleRate))
            #    #if self.calcsync:
            #    #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>Target[ChannelIndex],dg.dgm_CreateMetaDatumInt("CalcSync",1))
            #    #    pass
            #    #if ConvWarnFlag[ChannelIndex]:
            #    #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Warning","OVER"))
            #    #    pass
            #    pass
            
            # Now, if CalcSync, Wait for math.  ***!!!!!

            # Need wrapper for waitglobalrevcomputation!!!***
            #sys.stderr.write('19\n')
            #sys.stderr.flush()
            globalrev.wait_complete()
            #time.sleep(10)
        
        pass

    def GetSystemCaps(self,uint32_t CapsId):
        cdef uint32_t BufferSize=0;
        cdef np.ndarray buf
        err=CsGetSystemCaps(self.System,CapsId,NULL,&BufferSize)
        if err < 0:
            raise CSError("CsGetSystemCaps()",err)
        if int(CapsId) in syscaps_type_map: # Note: need to add more types to mapping!!!
            dtype=syscaps_type_map[int(CapsId)]
            pass
        assert((BufferSize % dtype.itemsize)==0) # buffer should be multiple of item size
        nelem = BufferSize // dtype.itemsize
        buf=np.zeros(nelem,dtype=dtype)
        err=CsGetSystemCaps(self.System,CapsId,buf.data,&BufferSize)
        if err < 0:
            raise CSError("CsGetSystemCaps()",err)
        assert(BufferSize==buf.nbytes) # Result size should match promised size

        return buf


    def GetSystemInfo(self):
        cdef np.ndarray SysInfo
        SysInfo=np.zeros(1,dtype=np.dtype([ ("Size",np.uint32),
                                            ("Pad0",np.uint32),
                                            ("MaxMemory",np.int64),
                                            ("SampleBits",np.uint32),
                                            ("SampleResolution",np.int32),
                                            ("SampleSize",np.uint32),
                                            ("SampleOffset",np.int32),
                                            ("BoardType",np.uint32),
                                            ("BoardName","a32"),
                                            ("AddonOptions",np.uint32),
                                            ("BaseBoardOption",np.uint32),
                                            ("TriggerMachinesCount",np.uint32),
                                            ("ChannelCount",np.uint32),
                                            ("BoardCount",np.uint32)],align=True))
        SysInfo[0]["Size"]=SysInfo.dtype.itemsize
        err=CsGetSystemInfo(self.System,<PCSSYSTEMINFO>SysInfo.data)
        if err < 0:
            raise CSError("CsGetSystemInfo()",err)

        #print("Got SysInfo: %s" % (str(SysInfo)))
        #print("self.System: "+str(self.System))
        return SysInfo
    
    
    def StartParamTransaction(self):
        assert(not self.InTransaction)
        self.WaitAbortAcq()
        self.InTransaction=1
        self.AcquisitionConfig=None
        self.ChannelConfig=None
        self.TriggerConfig=None
        pass

    def GetTriggerConfig(self):
        cdef np.ndarray TriggerArray
        cdef np.ndarray TriggerArrayEntry

        if self.TriggerConfig is None:
            # Initialize TriggerArray
            TriggerArray=np.zeros(1,dtype=self.ARRAY_TRIGGERCONFIG)
            TriggerArray[0]["TriggerCount"]=self.SysInfo[0]["TriggerMachinesCount"]
            for cnt in range(self.SysInfo[0]["TriggerMachinesCount"]):
                TriggerArray[0]["Trigger"][cnt]["Size"]=CSTRIGGERCONFIG.itemsize
                TriggerArray[0]["Trigger"][cnt]["TriggerIndex"]=cnt+1 # GAGE indexing seems to be by natural numbers
                TriggerArrayEntry=np.array(TriggerArray[0]["Trigger"][cnt],dtype=CSTRIGGERCONFIG)
                err = CsGet(self.System,gc.CS_TRIGGER,gc.CS_CURRENT_CONFIGURATION,TriggerArrayEntry.data)
                if err < 0:
                    raise CSError("CsGet()",err)
                TriggerArray[0]["Trigger"][cnt]=TriggerArrayEntry
                pass
            
            #err = CsGet(self.System,gc.CS_TRIGGER_ARRAY,gc.CS_CURRENT_CONFIGURATION,TriggerArray.data)
            #if err < 0:
            #    raise CSError("CsGet()",err)
            self.TriggerConfig = TriggerArray
            self.TriggerConfig_modified = TriggerArray.copy()
            
            pass
        pass

    def GetChannelConfig(self):
        cdef np.ndarray ChannelArray
        cdef np.ndarray ChannelArrayEntry

        if self.ChannelConfig is None:
            # Initialize ChannelArray
            ChannelArray=np.zeros(1,dtype=self.ARRAY_CHANNELCONFIG)
            ChannelArray[0]["ChannelCount"]=self.SysInfo[0]["ChannelCount"]
            for cnt in range(self.SysInfo[0]["ChannelCount"]):
                ChannelArray[0]["Channel"][cnt]["Size"]=CSCHANNELCONFIG.itemsize
                ChannelArray[0]["Channel"][cnt]["ChannelIndex"]=cnt+1 # GAGE indexing seems to be by natural numbers
                ChannelArrayEntry=np.array(ChannelArray[0]["Channel"][cnt],dtype=CSCHANNELCONFIG)
                err = CsGet(self.System,gc.CS_CHANNEL,gc.CS_CURRENT_CONFIGURATION,ChannelArrayEntry.data)
                if err < 0:
                    raise CSError("CsGet()",err)
                ChannelArray[0]["Channel"][cnt]=ChannelArrayEntry
                pass
            #print("ChannelArray: "+str(ChannelArray))
            #print("self.System: "+str(self.System))
            #err = CsGet(self.System,gc.CS_CHANNEL_ARRAY,gc.CS_CURRENT_CONFIGURATION,ChannelArray.data)
            #if err < 0:
            #    raise CSError("CsGet()",err)
            #print("ChannelArrayOut: "+str(ChannelArray))
            self.ChannelConfig = ChannelArray
            self.ChannelConfig_modified = ChannelArray.copy()
            sys.stdout.flush()
            
            pass
        pass


    def GetAcquisitionConfig(self):
        cdef np.ndarray AcqConfig
        if self.AcquisitionConfig is None:
            AcqConfig=np.zeros(1,dtype=CSACQUISITIONCONFIG)
            AcqConfig[0]["Size"]=AcqConfig.itemsize
            err = CsGet(self.System,gc.CS_ACQUISITION,gc.CS_CURRENT_CONFIGURATION,AcqConfig.data)
            if err < 0:
                raise CSError("CsGet()",err)
            self.AcquisitionConfig = AcqConfig
            self.AcquisitionConfig_modified = AcqConfig.copy()
            
            pass
        pass


    def SetTrigParam(self,name,trailingindex,value):
        cdef np.ndarray TriggerArrayEntry
        assert(self.InTransaction)

        self.GetTriggerConfig() # fill out self.TriggerConfig and self.TriggerConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        assert(ParamClass=="TRIG")
        
        self.TriggerConfig_modified[0]["Trigger"][trailingindex-1][name[4:]]=ParseValue(value)
        
        assert(self.TriggerConfig_modified.flags.c_contiguous)

        for cnt in range(self.SysInfo[0]["TriggerMachinesCount"]):
            TriggerArrayEntry=np.array(self.TriggerConfig_modified[0]["Trigger"][cnt],dtype=CSTRIGGERCONFIG)
            err = CsSet(self.System,gc.CS_TRIGGER,TriggerArrayEntry.data)
            if err < 0:
                raise CSError("CsSet(TriggerConfig)",err)
            pass
            
        #err = CsSet(self.System,gc.CS_TRIGGER_ARRAY,self.TriggerConfig_modified.data)
        #if err < 0:
        #    raise CSError("CsSet(TriggerConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect
        pass
    

    def AbortParamTransaction(self):
        """ For all param groups that have been modified, 
        re-write the original data back to the driver. 
        Then clear the transaction flag. """
        cdef np.ndarray TriggerConfig
        cdef np.ndarray ChannelConfig
        cdef np.ndarray AcquisitionConfig
        cdef np.ndarray ChannelArrayEntry
        cdef np.ndarray TriggerArrayEntry
        
        if self.TriggerConfig is not None:
            TriggerConfig=self.TriggerConfig
            for cnt in range(self.SysInfo[0]["TriggerMachinesCount"]):
                TriggerArrayEntry=np.array(TriggerConfig[0]["Trigger"][cnt],dtype=CSTRIGGERCONFIG)
                err = CsSet(self.System,gc.CS_TRIGGER,TriggerArrayEntry.data)   
                if err < 0:
                    raise CSError("CsSet(TriggerConfig)",err)
                pass
                
            #err = CsSet(self.System,gc.CS_TRIGGER_ARRAY,TriggerConfig.data)   
            #if err < 0:
            #    raise CSError("CsSet(TriggerConfig)",err)
            pass

        if self.ChannelConfig is not None:
            ChannelConfig=self.ChannelConfig
            for cnt in range(self.SysInfo[0]["ChannelCount"]):
                ChannelArrayEntry=np.array(ChannelConfig[0]["Channel"][cnt],dtype=CSCHANNELCONFIG)
                err = CsSet(self.System,gc.CS_CHANNEL,ChannelArrayEntry.data)
                if err < 0:
                    raise CSError("CsSet(ChannelConfig)",err)
                pass
            
            #err = CsSet(self.System,gc.CS_CHANNEL_ARRAY,ChannelConfig.data)   
            #if err < 0:
            #    raise CSError("CsSet(ChannelConfig)",err)
            pass

        if self.AcquisitionConfig is not None:
            AcquisitionConfig=self.AcquisitionConfig
            err = CsSet(self.System,gc.CS_ACQUISITION,AcquisitionConfig.data)   
            if err < 0:
                raise CSError("CsSet(AcquisitionConfig)",err)
            pass
        

        self.InTransaction=False
        self.TriggerConfig=None
        self.ChannelConfig=None
        self.AcquisitionConfig=None
        self.RestartAcq()

        pass
    
    def CommitParamTransaction(self):
        #sys.stderr.write('Running COMMIT\n')
        #sys.stderr.flush()
        err = CsDo(self.System,gc.ACTION_COMMIT_COERCE)
        if err < 0:
            raise CSError("CsDo(ACTION_COMMIT_COERCE)",err)
        
        self.InTransaction=False

        # Clear our knowlege as the CsDo probably
        # shifted things around
        self.TriggerConfig=None
        self.ChannelConfig=None
        self.AcquisitionConfig=None

        self.RestartAcq()

        pass

    def SetChanParam(self,name,trailingindex,value):
        cdef np.ndarray ChannelArrayEntry
        assert(self.InTransaction)

        self.GetChannelConfig() # fill out self.ChannelConfig and self.ChannelConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        assert(ParamClass=="CHAN")
        
        self.ChannelConfig_modified[0]["Channel"][trailingindex-1][name[4:]]=ParseValue(value)
        
        assert(self.ChannelConfig_modified.flags.c_contiguous)
        for cnt in range(self.SysInfo[0]["ChannelCount"]):
            ChannelArrayEntry=np.array(self.ChannelConfig_modified[0]["Channel"][cnt],dtype=CSCHANNELCONFIG)
            err = CsSet(self.System,gc.CS_CHANNEL,ChannelArrayEntry.data)
            if err < 0:
                raise CSError("CsSet(ChannelConfig)",err)
            pass
        #err = CsSet(self.System,gc.CS_CHANNEL_ARRAY,self.ChannelConfig_modified.data)
        #if err < 0:
        #    raise CSError("CsSet(ChannelConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect

        pass

    def SetAcquisitionParam(self,name,value):
        assert(self.InTransaction)
        self.GetAcquisitionConfig() # fill out self.AcquisitionConfig and self.AcquisitionConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        assert(ParamClass=="ACQ")
        
        self.AcquisitionConfig_modified[0][name]=ParseValue(value)
        
        assert(self.AcquisitionConfig_modified.flags.c_contiguous)
        err = CsSet(self.System,gc.CS_ACQUISITION,self.AcquisitionConfig_modified.data)
        if err < 0:
            raise CSError("CsSet(AcquisitionConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect


        pass


    def SetParam(self,name,trailingindex,value):
        assert(self.InTransaction)
        assert(name in self.ParamDict)

        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        if trailingindex != 1:
            assert(ParamClass=="TRIG" or ParamClass=="CHAN") # only TRIG and CHAN have multiple indices
            pass
        if ParamClass=="TRIG":
            self.SetTrigParam(name,trailingindex,value)
            pass
        elif ParamClass=="CHAN":
            self.SetChanParam(name,trailingindex,value)
            pass
        else:
            assert(ParamClass=="ACQ")
            self.SetAcquisitionParam(name,value)
            pass
        pass

    def GetTrigParamRaw(self,name,trailingindex):
        self.GetTriggerConfig()
        return self.TriggerConfig[0]["Trigger"][trailingindex-1][name[4:]]

    def GetChanParamRaw(self,name,trailingindex):
        self.GetChannelConfig()
        return self.ChannelConfig[0]["Channel"][trailingindex-1][name[4:]]

    def GetAcquisitionParamRaw(self,name):
        self.GetAcquisitionConfig()
        return self.AcquisitionConfig[0][name]

    def GetTrigParam(self,name,trailingindex):
        self.GetTriggerConfig()
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        return ReturnValue(self.TriggerConfig[0]["Trigger"][trailingindex-1][name[4:]])

    def GetChanParam(self,name,trailingindex):
        self.GetChannelConfig()
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        return ReturnValue(self.ChannelConfig[0]["Channel"][trailingindex-1][name[4:]])

    def GetAcquisitionParam(self,name):
        self.GetAcquisitionConfig()
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        return ReturnValue(self.AcquisitionConfig[0][name])
        

    def GetParam(self,name,trailingindex):
        assert(not self.InTransaction)
        assert(name in self.ParamDict)

        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = self.ParamDict[name]
        if trailingindex != 1:
            assert(ParamClass=="TRIG" or ParamClass=="CHAN") # only TRIG and CHAN have multiple indices
            pass
        if ParamClass=="TRIG":
            return self.GetTrigParam(name,trailingindex)
        elif ParamClass=="CHAN":
            return self.GetChanParam(name,trailingindex)
        else:
            assert(ParamClass=="ACQ")
            return self.GetAcquisitionParam(name)
        pass

    
    
    pass
