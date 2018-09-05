import sys
import numbers
import collections
import traceback
from threading import Thread

from dataguzzler_python.pydg import Module as pydg_Module
from dataguzzler_python.pydg import CurContext
from dataguzzler_python.pydg import u # PINT unit registry
from dataguzzler_python cimport dgold
from dataguzzler_python cimport wfmstore
from dataguzzler_python cimport dg_internal


import gageconstants as gc
#import pint # units library

from libc.stdint cimport uint64_t
from libc.stdint cimport int64_t
from libc.stdint cimport int32_t
from libc.stdint cimport uint32_t
from libc.stdint cimport int16_t
from libc.stdint cimport uint16_t
from libc.stdint cimport int8_t
from libc.stdint cimport uint8_t
from libc.errno cimport errno,EAGAIN,EINTR
from libc.stdlib cimport calloc,free
from posix.unistd cimport pipe,read,write

cdef extern from "ctype.h" nogil:
    int isdigit(int c)
    pass

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

from dataguzzler cimport dg_config

from dataguzzler cimport linklist as dgl
cimport dataguzzler as dg


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
    ("SegmentCountHigh",np.int32)])

CSCHANNELCONFIG = np.dtype([
    ("Size",np.uint32),
    ("ChannelIndex",np.uint32),
    ("Term",np.uint32),
    ("InputRange",np.uint32),
    ("Impedance",np.uint32),
    ("Filter",np.uint32),
    ("DcOffset",np.int32),
    ("Calib",np.int32)])

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
    ("Relation", np.uint32)])




# Data types for CsGetSystemCaps(): Note that only
# a few of these are defined, but you can add more if needed!

CSSAMPLERATETABLE = np.dtype([ ("SampleRate",np.int64),
                               ("strText",'a32')])
CSRANGETABLE = np.dtype([("InputRange",np.uint32),
                         ("strText",'a32'),
                         ("Reserved",np.uint32)])
CSIMPEDANCETABLE = np.dtype([("Impedance",np.uint32),
                             ("strText",'a32'),
                             ("Reserved",np.uint32)])


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
                errcodestr=buf.tostring().decode('utf-8')
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

    # System hardware information
    SysInfo=None
    
    # These variables may be None or contain the latest
    # cached knowledge of the configuration    
    AcquisitionConfig=None # CSACQUISITIONCONFIG
    ChannelConfig=None   # ARRAY_CHANNELCONFIG
    TriggerConfig=None  # ARRAY_TRIGGERCONFIG
    
    # These variables only valid during a (config) transction 
    cdef np.ndarray AcquisitionConfig_modified  # CSACQUISITIONCONFIG
    cdef np.ndarray ChannelConfig_modified    # ARRAY_CHANNELCONFIG
    cdef np.ndarray TriggerConfig_modified   # ARRAY_TRIGGERCONFIG

    # For acquisition thread
    AcquisitionThread=None
    
    cdef int pipe_fd_acqctrl[2]
    cdef int pipe_fd_acqresp[2]
    cdef int fd_triggered_read
    cdef int fd_end_acq_read



    # Variables used by acquisition thread
    # ***!!! MAY ONLY BE MODIFIED WHILE ACQUISITION THREAD IS PAUSED
    # Consider these as locked by the GIL -- only modified/accessed
    # while GIL is held
    cdef wfmstore.Channel **Channel
    cdef wfmstore.Wfm **Target # Array of target waveforms for acquisition thread -- valid only while acquiring
    cpdef int64_t PreTriggerSamples
    cpdef int64_t Length
    cpdef int64_t StartAddress
    cdef void **RawBuffers # Array of buffer pointers
    cpdef int32_t ChannelCount # Total number of available channels
    cpdef int32_t ChannelIncrement # Step size between channels
    cpdef uint32_t *InputRange
    cpdef uint32_t SampleSize
    cpdef int32_t SampleOffsetInQuantSteps # i32SampleOffset... Should be corresponding to the top of the detectable voltage range
    cpdef int32_t SampleResolution # Number of quantization in positive half of measurement range.... i.e. 10 bits -> 1024 steps total -> SampleResolution = 512 steps
    cpdef int32_t *DcOffset # Array of dc offsets in mV
    cpdef double *ProbeAtten
    cdef int64_t lastglobalrev
    
    
    def __init__(self,uint32_t boardtype,uint32_t numchannels,uint32_t samplebits,int16_t index):
        """ parameters boardtype (e.g. gagecontstants.CSXXXX_BOARDTYPE), numchannels, samplebits, and index used solely (per CsGetSystem() documentation) the
        board or boards to be initialized. These parameters may 
        be given as zero to represent "don't care". C"""
        err=CsInitialize()
        if err < 0:
            raise CSError("CsInitialize()",err)
        
        err=CsGetSystem(&self.System,boardtype,numchannels,samplebits,index)
        if err < 0:
            raise CSError("CsGetSystem()",err)

        self.Target=NULL
        self.RawBuffers=NULL
        self.InTransaction=0
        self.ChannelCount=0
        self.ChannelIncrement=1
        self.Length=0
        self.SysInfo=self.GetSystemInfo()
        self.ARRAY_TRIGGERCONFIG=np.dtype([ ("TriggerCount",np.uint32),
                                            ("Trigger",CSTRIGGERCONFIG,self.SysInfo.TriggerMachinesCount)])
        self.ARRAY_CHANNELCONFIG=np.dtype([ ("ChannelCount",np.uint32),
                                            ("Channel",CSCHANNELCONFIG,self.SysInfo.ChannelCount)])


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

        pass

    def StartAcqThread(self):
        self.AcquisitionThread = Thread(self.AcquisitionThreadCode)
        self.RestartAcq()
        pass
    
    cdef void ConvertChannelToVoltage(self,void *RawBuffer, wfmstore.Wfm *Target, int32_t ChannelIndex,uint32_t SampleSize,uint32_t InputRange, int32_t SampleOffsetInQuantSteps,int32_t SampleResolution,int32_t DcOffset,int64_t Length) nogil:
        # Called only in acquisition thread
        cdef uint8_t *Buf1
        cdef uint16_t *Buf2
        cdef uint32_t *Buf4
        cdef int64_t SampleCnt
        cdef double ScaleFactor
        ScaleFactor=(<double>InputRange)/<double>CS_GAIN_2_V
        
        if SampleSize==1:
            Buf1=<uint8_t *>RawBuffer
            for SampleCnt in range(Length):
                Target.Info.data[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf1[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass

        if SampleSize==2:
            Buf2=<uint16_t *>RawBuffer
            for SampleCnt in range(Length):
                Target.Info.data[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf2[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass

        if SampleSize==4:
            Buf4=<uint32_t *>RawBuffer
            for SampleCnt in range(Length):
                Target.Info.data[SampleCnt]=(SampleOffsetInQuantSteps-<double>Buf4[SampleCnt])*ScaleFactor/SampleResolution + DcOffset/1000.0
                pass
            pass
        
        pass
    
    def WaitAbortAcq(self):
        cdef ssize_t nbytes
        cdef char ctrlbyte=0
        if self.AcquisitionThread is None:
            return


        # Write 'A' for abort
        ctrlbyte='A'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqctrl[1],&ctrlbyte,1)
            err=errno
            pass
        
        # Wait for response of 'S' for stopped
        while ctrlbyte != 'S': 
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

        
        ChannelsPerBoard = self.SysInfo.ChannelCount//self.SysInfo.BoardCount
        MaskedMode = self.GetAcquisitionParam("Mode") & gc.CS_MASKED_MODE
        self.ChannelCount = self.SysInfo.ChannelCount
        self.ChannelIncrement = ChannelsPerBoard//MaskedMode

        NumAcqChannels=self.ChannelCount//self.ChannelIncrement

        if (self.Target != NULL and NumAcqChannels != OldAcqChannels) or not(self.Target):
            if self.Target:
                free(self.Target)
                pass
            self.Target=<wfmstore.Wfm **>calloc(sizeof(wfmstore.Wfm *)*(self.ChannelCount//self.ChannelIncrement),1)
            pass


        dgold.dg_enter_main_context()
        try:
            my_id=str(id(self))
            if (self.Channel != NULL and NumAcqChannels != OldAcqChannels) or not(self.Channel):
                if self.Channel:
                    for cnt in range(OldAcqChannels):
                        wfmstore.DeleteChannel(self.Channel[cnt],my_id)
                        pass
                    free(self.Channel)
                    pass
                self.Channel=<wfmstore.Channel **>calloc(sizeof(wfmstore.Channel *)*NumAcqChannels,1)

                for cnt in range(NumAcqChannels):
                    ChanName="CH%d" % (cnt+1)
                    self.Channel[cnt]=wfmstore.CreateChannel(ChanName,my_id,0,NULL,0)
                    pass
                pass
            pass
        finally:
            dgold.dg_leave_main_context()
            pass
        
        self.PreTriggerSamples = self.GetAcquisitionParam("TriggerHoldoff")
        self.Length=self.GetAcquisitionParam("Depth")

        self.SampleSize = self.GetAcquisitionParam("SampleSize")

            
        # Not sure I understand the start address calculation... it's not in the docs. This is based on the minimum start address formula from Events.c
        self.StartAddress = self.GetAcquisitionParam("TriggerDelay") + self.Length - self.GetAcquisitionParam("SegmentSize")
        
        if self.Length > self.GetAcquisitionParam("SegmentSize"):
            sys.stderr.write("CompuScope: Depth larger than SegmentSize")
            self.Length = self.GetAcquisitionParam("SegmentSize")
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
            self.InputRange[Cnt]=self.GetChannelParam("ChanInputRange",Cnt*self.ChannelIncrement)
            pass
        self.SampleOffsetInQuantSteps=self.GetAcquisitionParam("SampleOffset")

        self.SampleResolution=self.SysInfo.SampleResolution

        if (self.DcOffset != NULL and NumAcqChannels != OldAcqChannels) or not (self.DcOffset):
            if self.DcOffset:
                free(self.DcOffset)
                pass
            
            self.DcOffset=<int32_t *>calloc(sizeof(int32_t)*NumAcqChannels,1)
            pass
        
        for Cnt in range(NumAcqChannels):
            self.DcOffset[Cnt]=self.GetChannelParam("DcOffset",Cnt*self.ChannelIncrement)
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

        # Write 'G' for Go
        ctrlbyte='G'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqctrl[1],&ctrlbyte,1)
            err=errno
            pass
        pass
    
    cdef char acqthread_recv_cmd(self) nogil:
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=read(self.pipe_fd_acqctrl[0],&ctrlbyte,1)
            err=errno
            pass
        if nbytes != 1:
            # Treat error or EOF as quit command
            return 'Q'
        return ctrlbyte
    
    cdef char acqthread_wait_for_ok(self) nogil:
        cdef ssize_t nbytes
        cdef char ctrlbyte=0

        # Write 'S' for stopped
        ctrlbyte='S'
        err=EAGAIN
        while err==EAGAIN or err==EINTR:
            nbytes=write(self.pipe_fd_acqresp[1],&ctrlbyte,1)
            err=errno
            pass

        # Wait for response of 'G'
        while ctrlbyte != 'G': # G for go
            err=EAGAIN
            while err==EAGAIN or err==EINTR:
                nbytes=read(self.pipe_fd_acqctrl[0],&ctrlbyte,1)
                err=errno
                pass
            if nbytes != 1:
                # Treat error or EOF as quit command
                return 'Q'
            pass
        return ctrlbyte

    def acqthread_flushwfms(self,valid_data):
        cdef uint32_t AcqChannels = self.ChannelCount//self.ChannelIncrement
        cdef uint64_t idx
        cdef uint64_t Length=self.Length
        cdef wfmstore.Wfm **Target=self.Target
        cdef uint32_t ChannelIndex
        cdef float NaN=np.NaN
        
        if not valid_data:
            # Data invalid... fill with NaNs
            with nogil:
                for ChannelIndex in range(AcqChannels):
                    for idx in range(Length):
                        Target[ChannelIndex].Info.data[idx]=NaN
                        pass
                    pass                                
                pass
            pass
            
        with nogil:
            dgold.dg_enter_main_context_c()
            wfmstore.StartTransaction();
            for ChannelIndex in range(AcqChannels):
                wfmstore.NotifyChannel(self.Channel[ChannelIndex],self.Target[ChannelIndex],1);
                wfmstore.WfmUnreference(self.Target[ChannelIndex])
                self.Target[ChannelIndex]=NULL
                pass
            wfmstore.EndTransaction();
            dgold.dg_leave_main_context_c()
            pass
        
        pass
    
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

        cdef wfmstore.Wfm **Target
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

        cdef int32_t NumAcqChannels=ChannelCount//ChannelIncrement
        
        cdef IN_PARAMS_TRANSFERDATA InParams
        cdef OUT_PARAMS_TRANSFERDATA OutParams
        
        pollfds[0].fd = self.pipe_fd_acqctrl[0]
        pollfds[1].fd = self.fd_end_acq_read
        #pollfds[2].fd = self.fd_triggered_read

        pollfds[0].events=POLLIN
        pollfds[1].events=POLLIN
        #pollfds[2].events=POLLIN

        InParams.u32Segment=1
        InParams.u32Mode=gc.TxMODE_DEFAULT
        InParams.hNotifyEvent=NULL
        
        err=0
        
        while not Quit:
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

            InParams.i64StartAddress=self.StartAddress
            InParams.i64Length=self.Length
            
            # Make local copy of raw buffer data pointers
            Target=self.Target
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
            
            with nogil:
                # Start data acquisition
                err=CsDo(self.System,ACTION_START)
                if err < 0:
                    continue # Break out and report error 

                # NOTE: For win32 need to use WaitForSingleObject... See Gage Evetns.c/Threads.c example
                pollfds[0].revents=0
                pollfds[1].revents=0
                #pollfds[2].revents=0
                
                poll(pollfds,2,-1)

                if pollfds[0].revents & POLLIN:
                    acqcmd=self.acqthread_recv_cmd()
                    if acqcmd=='A': # abort
                        err=CsDo(self.System,ACTION_ABORT)
                        self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                        continue
                    if acqcmd=='Q': # quit
                        err=CsDo(self.System,ACTION_ABORT)
                        Quit=1
                        continue
                    pass

                if not(pollfds[1].revents & POLLIN):
                    err=1
                    errmsg="Poll returned without end_of_acquisition"
                    continue


                for ChannelIndex in range(NumAcqChannels): #range(1,self.ChannelCount+1,self.ChannelIncrement):
                    if err != 0:
                        continue  # raise any abort
                    
                    # Check for abort
                    poll(pollfds,1,0)
                    if pollfds[0].revents & POLLIN:
                        acqcmd=self.acqthread_recv_cmd()
                        if acqcmd=='A': # abort
                            err=CsDo(self.System,ACTION_ABORT)
                            self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                            continue
                        if acqcmd=='Q': # quit
                            err=CsDo(self.System,ACTION_ABORT)
                            Quit=1
                            continue
                        pass

                    InParams.u16Channel=1+ChannelIndex*ChannelIncrement
                    InParams.pDataBuffer=RawBuffers[ChannelIndex]
                    err=CsTransfer(self.System,&InParams,&OutParams)
                    
                    pass

                dgold.dg_enter_main_context_c()
                wfmstore.StartTransaction()
                for ChannelIndex in range(self.ChannelCount//self.ChannelIncrement):
                    self.Target[ChannelIndex]=wfmstore.CreateWfm(self.Channel[ChannelIndex],0,NULL) # We get a WfmReference() from CreateWfm. This is paired with WfmUnreference() in MetaDataDone().
                    dimlen=self.Length
                    wfmstore.WfmAlloc(self.Target[ChannelIndex],dimlen,1,&dimlen)
                
                    pass
                wfmstore.EndTransaction()
                
                # !!!*** From hereon in case of abort need to NotifyChannel() and
                # WfmUnfererence the Wfms   using self.acqthread_flushwfms(valid_data)   !!!****
            
                self.lastglobalrev=wfmstore.globalrevision
                dgold.dg_leave_main_context_c()

                # Now do the conversions
                for ChannelIndex in range(ChannelCount//ChannelIncrement):
                    # Check for abort
                    poll(pollfds,1,0)
                    if pollfds[0].revents & POLLIN:
                        acqcmd=self.acqthread_recv_cmd()
                        if acqcmd=='A': # abort
                            err=CsDo(self.System,ACTION_ABORT)
                            with gil:
                                self.acqthread_flushwfms(False)
                                pass
                            self.acqthread_wait_for_ok() # report we are stopped. Wait for the goahead to continue
                            continue
                        if acqcmd=='Q': # quit
                            err=CsDo(self.System,ACTION_ABORT)
                            with gil:
                                self.acqthread_flushwfms(False)
                                pass

                            Quit=1
                            continue
                        pass

                    self.ConvertChannelToVoltage(RawBuffers[ChannelIndex],Target[ChannelIndex],ChannelIndex,SampleSize,InputRange[ChannelIndex],SampleOffsetInQuantSteps,SampleResolution,DcOffset[ChannelIndex],Length)
                    pass

                pass

            # (if we wanted to be ambitious here, we could spawn this
            # next stuff off as a separate thread and start acquiring
            # the next data now)
            
            # Now get metadata ***!!!! (NEED TO IMPLEMENT)

            # ...


            for ChannelIndex in range(ChannelCount//ChannelIncrement):
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumInt("Channel",1+ChannelIndex*(ChannelCount//ChannelIncrement)))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("ProbeAtten",self.ProbeAtten[ChannelIndex]))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("MaxLevel",(<double>self.InputRange[ChannelIndex])/2000.0))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("MinLevel",-(<double>self.InputRange[ChannelIndex])/2000.0))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("AmplUnits","Volts"))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("AmplCoord","Voltage"))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Coord1","Time"))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Units1","seconds"))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("IniVal1",-self.PreTriggerSamples*1.0/self.SampleRate))
                dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumDbl("Step1",-1.0/self.SampleRate))
                if self.calcsync:
                    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>Target[ChannelIndex],dg.dgm_CreateMetaDatumInt("CalcSync",1))
                    pass
                #if ConvWarnFlag[ChannelIndex]:
                #    dg.dgm_AddMetaDatumWI(<dg.dg_wfminfo *>self.Target[ChannelIndex],dg.dgm_CreateMetaDatumStr("Warning","OVER"))
                #    pass
                pass

            self.acqthread_flushwfms(True) # Notfiy that wfms are complete

            
            # Now, if CalcSync, Wait for math.  ***!!!!!

            # Need wrapper for waitglobalrevcomputation!!!***
            pass
        
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
                                            ("BoardCount",np.uint32)]))
        
        err=CsGetSystemInfo(self.System,<PCSSYSTEMINFO>SysInfo.data)
        if err < 0:
            raise CSError("CsGetSystemInfo()",err)

        return SysInfo
    
    
    def StartParamTransaction(self):
        assert(not self.InTransaction)
        self.WaitAbortAcq()
        self.InTransaction=1
        self.AcquistionConfig=None
        self.ChannelConfig=None
        self.TriggerConfig=None
        pass

    def GetTriggerConfig(self):
        cdef np.ndarray TriggerArray
        if self.TriggerConfig is None:
            # Initialize TriggerArray
            TriggerArray=np.zeros(1,dtype=self.ARRAY_TRIGGERCONFIG)
            TriggerArray.TriggerCount=self.SysInfo.TriggerMachinesCount
            for cnt in range(self.SysInfo.TriggerMachinesCount):
                TriggerArray.Trigger[cnt].Size=CSTRIGGERCONFIG.itemsize
                TriggerArray.Trigger[cnt].TriggerIndex=cnt+1 # GAGE indexing seems to be by natural numbers
                pass
            
            err = CsGet(self.System,gc.CS_TRIGGER_ARRAY,gc.CS_CURRENT_CONFIGURATION,TriggerArray.data)
            if err < 0:
                raise CSError("CsGet()",err)
            self.TriggerConfig = TriggerArray
            self.TriggerConfig_modified = TriggerArray.copy()
            
            pass
        pass

    def GetChannelConfig(self):
        cdef np.ndarray ChannelArray
        
        if self.ChannelConfig is None:
            # Initialize ChannelArray
            ChannelArray=np.zeros(1,dtype=self.ARRAY_CHANNELCONFIG)
            ChannelArray.ChannelCount=self.SysInfo.ChannelCount
            for cnt in range(self.SysInfo.ChannelCount):
                ChannelArray.Channel[cnt].Size=CSCHANNELCONFIG.itemsize
                ChannelArray.Channel[cnt].ChannelIndex=cnt+1 # GAGE indexing seems to be by natural numbers
                pass
            
            err = CsGet(self.System,gc.CS_CHANNEL_ARRAY,gc.CS_CURRENT_CONFIGURATION,ChannelArray.data)
            if err < 0:
                raise CSError("CsGet()",err)
            self.ChannelConfig = ChannelArray
            self.ChannelConfig_modified = ChannelArray.copy()
            
            pass
        pass


    def GetAcquisitionConfig(self):
        cdef np.ndarray AcqConfig
        if self.AcquisitionConfig is None:
            AcqConfig=np.zeros(1,dtype=CSACQUISITIONCONFIG)
            AcqConfig.Size=AcqConfig.itemsize
            err = CsGet(self.System,gc.CS_ACQUISITION,gc.CS_CURRENT_CONFIGURATION,AcqConfig.data)
            if err < 0:
                raise CSError("CsGet()",err)
            self.AcquisitionConfig = AcqConfig
            self.AcquisitionConfig_modified = AcqConfig.copy()
            
            pass
        pass


    def SetTrigParam(self,name,trailingindex,value):
        assert(self.InTransaction)

        self.GetTriggerConfig() # fill out self.TriggerConfig and self.TriggerConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = ParamDict[name]
        assert(ParamClass=="TRIG")
        
        setattr(self.TriggerConfig_modified.Trigger[trailingindex-1],name,ParseValue(value))
        
        assert(self.TriggerConfig_modified.c_contiguous)
        err = CsSet(self.System,gc.CS_TRIGGER_ARRAY,self.TriggerConfig_modified.data)
        if err < 0:
            raise CSError("CsSet(TriggerConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect
        pass
    

    def AbortParamTransaction(self):
        """ For all param groups that have been modified, 
        re-write the original data back to the driver. 
        Then clear the transaction flag. """
        cdef np.ndarray TriggerConfig
        cdef np.ndarray ChannelConfig
        cdef np.ndarray AcquisitionConfig
        
        if self.TriggerConfig is not None:
            TriggerConfig=self.TriggerConfig
            err = CsSet(self.System,gc.CS_TRIGGER_ARRAY,TriggerConfig.data)   
            if err < 0:
                raise CSError("CsSet(TriggerConfig)",err)
            pass

        if self.ChannelConfig is not None:
            ChannelConfig=self.ChannelConfig
            err = CsSet(self.System,gc.CS_CHANNEL_ARRAY,ChannelConfig.data)   
            if err < 0:
                raise CSError("CsSet(ChannelConfig)",err)
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
        assert(self.InTransaction)

        self.GetChannelConfig() # fill out self.ChannelConfig and self.ChannelConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = ParamDict[name]
        assert(ParamClass=="CHAN")
        
        setattr(self.ChannelConfig_modified.Chan[trailingindex-1],name,ParseValue(value))
        
        assert(self.ChannelConfig_modified.c_contiguous)
        err = CsSet(self.System,gc.CS_CHANNEL_ARRAY,self.ChannelConfig_modified.data)
        if err < 0:
            raise CSError("CsSet(ChannelConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect

        pass

    def SetAcquisitionParam(self,name,value):
        assert(self.InTransaction)
        self.GetAcquisitionConfig() # fill out self.AcquisitionConfig and self.AcquisitionConfig_modified if not already set. 

        
        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = ParamDict[name]
        assert(ParamClass=="ACQ")
        
        setattr(self.AcquisitionConfig_modified,name,ParseValue(value))
        
        assert(self.AcquisitionConfig_modified.c_contiguous)
        err = CsSet(self.System,gc.CS_ACQUISITION,self.AcquisitionConfig_modified.data)
        if err < 0:
            raise CSError("CsSet(AcquisitionConfig)",err)
        
        # Need to CommitParamTransaction() for this to take effect


        pass


    def SetParam(self,name,trailingindex,value):
        assert(self.InTransaction)
        assert(name in ParamDict)

        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = ParamDict[name]
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

    def GetTrigParam(self,name,trailingindex):
        self.GetTriggerConfig()
        return getattr(self.TriggerConfig.Trigger[trailingindex-1],name)

    def GetChanParam(self,name,trailingindex):
        self.GetChannelConfig()
        return getattr(self.ChannelConfig.Channels[trailingindex-1],name)

    def GetAcquisitionParam(self,name):
        self.GetAcquisitionConfig()
        return getattr(self.AquisitionConfig,name)
        

    def GetParam(self,name,trailingindex,value):
        assert(not self.InTransaction)
        assert(name in ParamDict)

        (ParamClass,dtype,ReturnValue,ParseValue,HelpInfo) = ParamDict[name]
        if trailingindex != 1:
            assert(ParamClass=="TRIG" or ParamClass=="CHAN") # only TRIG and CHAN have multiple indices
            pass
        if ParamClass=="TRIG":
            self.GetTrigParam(name,trailingindex)
            pass
        elif ParamClass=="CHAN":
            self.GetChanParam(name,trailingindex)
            pass
        else:
            assert(ParamClass=="ACQ")
            self.GetAcquisitionParam(name)
            pass
        pass

    
    
    pass

# Index into ModeStrs list is bitnum. 
AcqModeStrs = [ "SINGLE","DUAL","QUAD","OCT", # 0x1 - 0x8 
             None,None,None,"POWER_ON", # 0x10 - 0x80
             None,"PRETRIG_MULREC","REFERENCE_CLK","CS3200_CLK_INVERT", # 0x100-0x800
             "SW_AVERAGING" ] # 0x1000

AcqModeStrs_array=np.array(AcqModeStrs,dtype=np.object)


TimeStampModeStrs = [ "TIMESTAMP_MCLK", None, None, None, # 0x1 - 0x8 
                      "TIMESTAMP_FREERUN",None,] # 0x10 

TimeStampModeStrs_array=np.array(TimeStampModeStrs,dtype=np.object)

TermStrs = [ "CS_COUPLING_DC", "CS_COUPLING_AC", "CS_DIFFERENTIAL_INPUT", "CS_DIRECT_ADC_INPUT", ] # 0x1 - 0x8 

TermStrs_array=np.array(TermStrs,dtype=np.object)



def PrintMode(mode,ModeStrs_array):
    ModeNums = np.arange(ModeStrs_array.shape[0])
    ModeBits = 1 << ModeNums
    
    ModeBitsInMode = ModeBits & mode
    ModeStrsInMode = ModeStrs_array[ModeBitsInMode.astype(np.bool)]
    return "|".join(ModeStrsInMode)

def ParseMode(ModeStr,ModeStrs,ModeStrs_array):

    if isinstance(ModeStr,numbers.Number):
        return int(ModeStr) # Can directly process an integer mode
    
    Strs=ModeStr.split("|")
    value=0
    for M in Strs:
        try: 
            bitnum = ModeStrs.index(M.strip())
            pass
        except ValueError:
            raise ValueError("Mode bit %s not found. Valid possibilities: %s" % (M.strip(),ModeStrs_array[ModeStrs_array != None]))
            pass
        value |= (1 << bitnum)
        pass
    return value

def PrintTriggerTimeout(val):
    if val==gc.CS_TIMEOUT_DISABLE:
        return "TIMEOUT_DISABLE"
    else:
        return (val*100e-9)*u.second
    pass

def ParseTriggerTimeout(val):
    if val=="TIMEOUT_DISABLE":
        return gc.CS_TIMEOUT_DISABLE
    return float(val/u.second)/100e-9

ParamDict={
    # Contents:
    # ParamName: (ParamClass(either "TRIG","CHAN",or"ACQ"),numpy dtype,function_to_interpret_hw_value,function_to_assign_hw_value,HelpInfo)
    "SampleRate": ("ACQ",np.int64,lambda val: val*u.Hz, lambda rate: int(round(rate/u.Hz)),"the sampling rate in Hz"),
    "ExtClk": ("ACQ",np.bool,lambda val: { True: "ENABLED", False: "DISABLED"}[val], lambda state: {"ENABLED": True,"DISABLED": False}[state],"whether ExtClk is ENABLED or DISABLED"),
    "ExtClkSampleSkip": ("ACQ",np.uint32, None, None,"number of ExtClk samples skipped"),
    "Mode": ("ACQ", np.uint32, lambda num: PrintMode(num,AcqModeStrs_array), lambda  m: ParseMode(m,AcqModeStrs,AcqModeStrs_array),"acquisition mode bits, selected from %s" % (AcqModeStrs_array[AcqModeStrs_array != None])),
    "SampleBits": ("ACQ", np.uint32, lambda val: val, lambda num: np.uint32(num),"Vertical resolution in bits of the acquisition"),
    "SampleRes": ("ACQ", np.int32, lambda val: val, lambda num: np.int32(num),"Sample resolution. This seems to be the number of quantization steps in the positive half of the measurement range (?)"),
    "SampleSize": ("ACQ", np.uint32, lambda val: val, lambda num: np.uint32(num),"Sample size for acquisition, in bytes per sample"),
    "SegmentCount": ("ACQ", np.uint32, lambda val: val, lambda num: np.uint32(num),"Number of segments for acquisition (more than 1 will probably fail to work with this code)"),
    "Depth": ("ACQ", np.int64, lambda val: val, lambda num: np.int64(num),"Number of samples to capture after the trigger event"),
    "SegmentSize": ("ACQ", np.int64, lambda val: val, lambda num: np.int64(num),"Maximum number of samples in a segment"),
    "TriggerTimeout": ("ACQ",np.int64, PrintTriggerTimeout, ParseTriggerTimeout,"Amount of time to wait (in 100 nanoseconds units) after start of segment acquisition before forcing a trigger event. CS_TIMEOUT_DISABLE means infinite timeout."),
    "TrigEnginesEn": ("ACQ",np.bool,lambda val: { True: "ENABLED", False: "DISABLED"}[val], lambda state: {"ENABLED": True,"DISABLED": False}[state],"whether Trigger engines are ENABLED or DISABLED"),

    "TriggerDelay": ("ACQ", np.int64, lambda val: val, lambda num: np.int64(num),"Number of samples to skip after trigger before decrementing depth counter"),

    "TriggerHoldoff": ("ACQ", np.int64, lambda val: val, lambda num: np.int64(num),"Number of samples to acquire before enabling trigger circuitry, i.e. pretrigger amount"),
    "SampleOffset": ("ACQ", np.int32, lambda val: val, lambda num: np.int32(num),"System sample offset"),
    "TimeStampConfig": ("ACQ", np.uint32, lambda num: PrintMode(num,TimeStampModeStrs_array), lambda  m: ParseMode(m,TimeStampModeStrs,TimeStampModeStrs_array),"Time stamp mode bits, selected from %s" % (TimeStampModeStrs_array[TimeStampModeStrs_array != None])),
    # !!!*** Need to do rest of parameters here !!!***
    # i.e Channel (CHAN) paramters and trigger (TRIG) parameters

    "ChanTerm": ("CHAN",np.uint32,lambda num: PrintMode(num,TermStrs_array), lambda  m: ParseMode(m,TermStrs,TermStrs_array),"Termination mode bits, selected from %s" % (TermStrs_array[TermStrs_array != None])),
    "ChanInputRange": ("CHAN",np.uint32,lambda val: (val/1000.0)*u.volt, lambda voltage: int(round((voltage/u.volt)*1000.0)),"Input range in volts"),
    "ChanImpedance": ("CHAN",np.uint32,lambda val: val*u.Ohm, lambda res: int(round((res/u.Ohm))),"Input impedance in Ohms (50 or 1,000,000)"),
    "ChanFilter": ("CHAN", np.uint32,lambda val: val, lambda num: np.uint32(num),"Filter index for this channel, or 0"),
    "ChanDcOffset": ("CHAN",np.int32,lambda val: (val/1000.0)*u.volt, lambda voltage: int(round((voltage/u.volt)*1000.0)),"DC Offset in volts"),
    "ChanCalib": ("CHAN",np.int32,lambda val: val, lambda num: np.int32(num),"Channel auto-calibration method (default 0)"),


    "TrigCondition": ("TRIG",np.uint32,lambda val: ["NEG_SLOPE","POS_SLOPE"][val],lambda cond: { "NEG_SLOPE": 0, "POS_SLOPE":1 }[cond],"Trigger condition: NEG_SLOPE or POS_SLOPE"),
    "TrigLevel": ("TRIG",np.int32,lambda val: val/100.0,lambda lev: np.int32(lev*100.0),"Trigger level as a fraction of full scale value"),
    "TrigSource": ("TRIG",np.int32,lambda val: {0:"DISABLE",1:"CHAN_1",2:"CHAN_2",3:"CHAN_3",4:"CHAN_4",5:"CHAN_5",6:"CHAN_6",7:"CHAN_7",8:"CHAN_8",-1:"EXT"}[val],lambda src: { "DISABLE": 0, "CHAN_1":1, "CHAN_2":2, "CHAN_3":3, "CHAN_4":4, "CHAN_5":5, "CHAN_6": 6, "CHAN_7":7, "CHAN_8":8, "EXT":-1}[src],"Trigger source: DISABLE, CHAN_x, or EXT"),
    "TrigExtCoupling": ("TRIG",np.uint32, lambda val: { 1:"DC",2:"AC"}[val],lambda coupling: { "DC": 1, "AC":2 }[coupling],"External trigger coupling: DC or AC"),
    "TrigExtTriggerRange": ("TRIG",np.uint32,lambda val: (val/1000.0)*u.volt, lambda voltage: int(round((voltage/u.volt)*1000.0)),"External trigger full scale range, in Volts"),
    "TrigExtTriggerImpedance": ("TRIG",np.uint32, lambda val: val*u.Ohm, lambda res: int(round((res/u.Ohm))),"External trigger impedance in Ohms (50 or 1,000,000)"),
    "TrigRelation": ("TRIG",np.uint32,lambda val: ["OR","AND"][val],lambda rel: { "OR": 0, "AND":1 }[rel],"Trigger engine relation: OR or AND"),
}


def index_from_param(name):
    trailingdigits=""
    while isdigit(name[-1]):
        trailingdigits=name[-1]+trailingdigits
        name=name[:-1]
        pass
    
    if len(trailingdigits) > 0:
        trailingindex=int(trailingdigits)
        pass
    else:
        trailingindex=1  # Gage indexing generally starts with 1
        pass
    return (name,trailingindex)
    
class ParamAttribute(object):
    # Descriptor class. Instances of this are returned
    # by __getattribute__ on the CompuScope class
    # for each of the parameters (including with
    # numbered suffixes) in ParamDict
    # https://docs.python.org/2/howto/descriptor.html
    Name=None
    trailingindex=None
    
    def __init__(self,Name,trailingindex,doc):
        self.Name=Name
        self.trailingindex=trailingindex
        self.__doc__=doc
        pass
    
    def __get__(self,obj,type=None):

        return obj.LowLevel.GetParam(self.Name,self.trailingindex)
            

    def __set__(self,obj,value):
        obj.LowLevel.StartParamTransaction()
        try:
            obj.LowLevel.SetParam(self.Name,self.trailingindex,value)
            obj.LowLevel.CommitParamTransaction()
            pass
        except:
            obj.LowLevel.AbortParamTransaction()
            raise
        pass
    pass
    


class CompuScope(object,metaclass=pydg_Module):
    # pydg_Module ensures that all calls to this are within the same thread
    LowLevel=None
        
    
    def __init__(self,uint32_t boardtype, uint32_t numchannels, uint32_t samplebits, int16_t index,**params):
        """ Create a CompuScope object for a specified
        CompuScope system. The system is specified by 
        board type (see BOARDTYPE defines in gageconstants.py)
        or zero representing any board type, 
        by number of channels (again zero representing any number),
        by bits of resolution (again zero representing any number), 
        and by index of matching boards (Gage documentation is 
        ambiguous about whether index starts at 0 or 1). 

        All parameters will be left at preexisting values 
        (presumably last-used or driver default) unless 
        provided as additional keyword parameters, that are 
        applied as per the update() method.
"""

        #assert(sizeof(TCHAR)==1)

        self.LowLevel=CSLowLevel(boardtype,numchannels,samplebits,index)
        
        self.update(**params)

        self.LowLevel.StartAcqThread()
        
        pass

    def update_dict(self,params):
        """ Assign multiple parameters as a single operation
        based on a dictionary """
        
        self.LowLevel.StartParamTransaction()
        try:
            for name in params:
                (name_noindex,trailingindex)=index_from_param(name)
                value=params[name]
                
                self.LowLevel.SetParam(name_noindex,trailingindex,value)
                pass
            
            self.LowLevel.CommitParamTransaction()
            pass
        except:
            self.LowLevel.AbortParamTransaction()
            raise
        
        pass
    
    def update(self,**params):
        """ Update a set of parameters as a single operation,
        based on named keyword arguments"""


        """Following concern is not valid because parameter validation
        happens only when CsDo() is executed: Note that
        in some cases the order in which they are applied might matter, 
        because one parameter value might influence allowable possibilities
        for another. In python 3.6 and beyond the order of keyword arguments
        is preserved and this will happen correctly. For prior python versions,
        user update_dict and pass a collections.OrderedDict(). """

        return self.update_dict(params)

    #def __getattr__(self,name):
    #    # Return a function 
    #    # representing a particular parameter
    #
    #    (name,trailingindex) = index_from_param(name)
    #    
    #    if name in ParamDict:
    #        def ParamFunc(value=None):
    #            if value is not None:
    #                self.LowLevel.StartParamTransaction()
    #                try:
    #                    self.LowLevel.SetParam(name,trailingindex,value)
    #                    self.LowLevel.CommitParamTransaction()
    #                    pass
    #                except:
    #                    self.LowLevel.AbortParamTransaction()
    #                    raise
    #                pass
    #            return self.LowLevel.GetParam(name,trailingindex)
    #        ParamFunc.__name__=name
    #        ParamFunc.__doc__="Get or set (if value is not None) %s." % (ParamDict[name][4])
    #        return ParamFunc
    #    else:
    #        raise AttributeError
    #    pass

    def __getattribute__(self,attrname):
        # WARNING: pydg.Module does NOT wrap __getattribute__
        # and ensure it is executed in our thread context, but it
        # DOES wrap whatever we return

        (name,trailingindex) = index_from_param(attrname)        
        if name in ParamDict:
            return ParamAttribute(name,trailingindex,ParamDict[name][4])
        # Fall through to default behavior if we don't have this attribute
        
        return object.__getattribute__(self,attrname)
            
    def get_all_params(self):
        TrigCount=self.LowLevel.SysInfo.TriggerMachinesCount
        ChanCount=self.LowLevel.SysInfo.ChannelCount

        AcqParamDict={ ParamName: ParamVal for (ParamName,ParamVal) in ParamDict.items() if ParamVal[0]=="ACQ"}
        TrigParamDict={ ParamName: ParamVal for (ParamName,ParamVal) in ParamDict.items() if ParamVal[0]=="TRIG"}
        ChanParamDict={ ParamName: ParamVal for (ParamName,ParamVal) in ParamDict.items() if ParamVal[0]=="CHAN"}
        
        paramlist=[]

        for ParamName in AcqParamDict:
            paramlist.append(ParamName)
            pass
        
        for ParamName in ChanParamDict:
            for Cnt in range(ChanCount):
                paramlist.append("%s%d" % (ParamName,Cnt+1))
                pass
            pass

        for ParamName in TrigParamDict:
            for Cnt in range(TrigCount):
                paramlist.append("%s%d" % (ParamName,Cnt+1))
                pass
            pass
        
        return paramlist
    
    
    def __dir__(self):
        """ Return a list of attribute names """
        physattribs = super(CompuScope,self).__dir__()

        dynattribs=self.get_all_params()

        return physattribs+dynattribs
        
    def queryall(self):
        """ Query all settable parameters. Returns ordered dictionary
        that can be passed to update() method"""
        queryresp=collections.OrderedDict()
        for paramname in self.get_all_params():
            (name,trailingindex) = index_from_param(paramname)
            value=self.LowLevel.GetParam(name,trailingindex)
            queryresp[paramname]=value
            pass
        return queryresp
    
    pass

# How to handle SET query (i.e. SET?) ANSWER: queryall() method