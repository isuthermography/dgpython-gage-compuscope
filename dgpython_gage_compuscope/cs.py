import sys
import numbers
import collections
import traceback
from threading import Thread

from dataguzzler_python.pydg import Module as pydg_Module
from dataguzzler_python.pydg import CurContext
from dataguzzler_python.pydg import RunInContext
from dataguzzler_python.pydg import u # PINT unit registry

from . import gageconstants as gc
import numpy as np

from .cs_lowlevel import CSLowLevel

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
        M=M.strip()
        if len(M) > 0:
            try: 
                bitnum = ModeStrs.index(M.strip())
                pass
            except ValueError:
                raise ValueError("Mode bit %s not found. Valid possibilities: %s" % (M.strip(),ModeStrs_array[ModeStrs_array != None]))
                pass
            value |= (1 << bitnum)
            pass
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
    "ExtClkSampleSkip": ("ACQ",np.uint32, lambda val: val, lambda val: val,"number of ExtClk samples skipped"),
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
    "ChanImpedance": ("CHAN",np.uint32,lambda val: val*u.ohm, lambda res: int(round((res/u.ohm))),"Input impedance in Ohms (50 or 1,000,000)"),
    "ChanFilter": ("CHAN", np.uint32,lambda val: val, lambda num: np.uint32(num),"Filter index for this channel, or 0"),
    "ChanDcOffset": ("CHAN",np.int32,lambda val: (val/1000.0)*u.volt, lambda voltage: int(round((voltage/u.volt)*1000.0)),"DC Offset in volts"),
    "ChanCalib": ("CHAN",np.int32,lambda val: val, lambda num: np.int32(num),"Channel auto-calibration method (default 0)"),


    "TrigCondition": ("TRIG",np.uint32,lambda val: ["NEG_SLOPE","POS_SLOPE"][val],lambda cond: { "NEG_SLOPE": 0, "POS_SLOPE":1 }[cond],"Trigger condition: NEG_SLOPE or POS_SLOPE"),
    "TrigLevel": ("TRIG",np.int32,lambda val: val/100.0,lambda lev: np.int32(lev*100.0),"Trigger level as a fraction of full scale value"),
    "TrigSource": ("TRIG",np.int32,lambda val: {0:"DISABLE",1:"CHAN_1",2:"CHAN_2",3:"CHAN_3",4:"CHAN_4",5:"CHAN_5",6:"CHAN_6",7:"CHAN_7",8:"CHAN_8",-1:"EXT"}[val],lambda src: { "DISABLE": 0, "CHAN_1":1, "CHAN_2":2, "CHAN_3":3, "CHAN_4":4, "CHAN_5":5, "CHAN_6": 6, "CHAN_7":7, "CHAN_8":8, "EXT":-1}[src],"Trigger source: DISABLE, CHAN_x, or EXT"),
    "TrigExtCoupling": ("TRIG",np.uint32, lambda val: { 1:"DC",2:"AC"}[val],lambda coupling: { "DC": 1, "AC":2 }[coupling],"External trigger coupling: DC or AC"),
    "TrigExtTriggerRange": ("TRIG",np.uint32,lambda val: (val/1000.0)*u.volt, lambda voltage: int(round((voltage/u.volt)*1000.0)),"External trigger full scale range, in Volts"),
    "TrigExtImpedance": ("TRIG",np.uint32, lambda val: val*u.ohm, lambda res: int(round((res/u.ohm))),"External trigger impedance in Ohms (50 or 1,000,000)"),
    "TrigRelation": ("TRIG",np.uint32,lambda val: ["OR","AND"][val],lambda rel: { "OR": 0, "AND":1 }[rel],"Trigger engine relation: OR or AND"),
}


def index_from_param(name):
    trailingdigits=""
    while str.isdigit(name[-1]):
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
        sys.stderr.write("StartParamTransaction()\n")
        sys.stderr.flush()
        obj.LowLevel.StartParamTransaction()
        try:
            sys.stderr.write("SetParam()\n")
            sys.stderr.flush()
            obj.LowLevel.SetParam(self.Name,self.trailingindex,value)
            sys.stderr.write("Commit()\n")
            sys.stderr.flush()
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
        
    
    def __init__(self,boardtype,numchannels,samplebits,index,**params):
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

        self.LowLevel=CSLowLevel(ParamDict,boardtype,numchannels,samplebits,index)
        
        self.update(**params)

        self.LowLevel.StartAcqThread()

        for paramname in self.get_all_params:
            
            # Create Descriptor for this parameter
            descr = ParamAttribute(name,trailingindex,ParamDict[name][4])
            self.__dict__[paramname] = descr

            pass
        
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

    #def __getattribute__(self,attrname):
    #    # WARNING: pydg.Module does NOT wrap __getattribute__
    #    # and ensure it is executed in our thread context, but it
    #    # DOES wrap whatever we return
    #
    #    (name,trailingindex) = index_from_param(attrname)        
    #    if name in ParamDict:
    #        # We have to run the descriptor
    #        # in our context
    #        descr = ParamAttribute(name,trailingindex,ParamDict[name][4])
    #        retval=RunInContext(self,descr.__get__,"__get__",(self,),{})
    #       
    #        # retval.__doc__=  ### Need to set docstring on a proxy object or wrapper instead
    #        return retval
    #
    #    # Fall through to default behavior if we don't have this attribute
    #    
    #    return object.__getattribute__(self,attrname)
    #
    #def __setattr__(self,attrname,value):
    #    (name,trailingindex) = index_from_param(attrname)        
    #    if name in ParamDict:
    #        descr = ParamAttribute(name,trailingindex,ParamDict[name][4])
    #        sys.stderr.write("Calling descriptor %s __set__ method\n" % (name))
    #        sys.stderr.flush()
    #        descr.__set__(self,value)
    #        pass
    #    # Fall through to default behavior if we don't have this attribute
    #    
    #    return object.__setattr__(self,attrname,value)
        

    def get_all_params(self):
        TrigCount=self.LowLevel.SysInfo[0]["TriggerMachinesCount"]
        ChanCount=self.LowLevel.SysInfo[0]["ChannelCount"]

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
