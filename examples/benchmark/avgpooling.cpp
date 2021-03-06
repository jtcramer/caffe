// Copyright 2013 Yangqing Jia

#include <cuda_runtime.h>
#include <fcntl.h>
#include <google/protobuf/text_format.h>

#include <cstring>
#include <ctime>
#include <cstdio>
#include <sstream>

#include "caffe/blob.hpp"
#include "caffe/common.hpp"
#include "caffe/net.hpp"
#include "caffe/filler.hpp"
#include "caffe/proto/caffe.pb.h"
#include "caffe/util/io.hpp"
#include "caffe/solver.hpp"
#include "caffe/vision_layers.hpp"
#include <sys/time.h>

using namespace caffe;
using namespace std;

double read_timer(){
    struct timeval start;
    gettimeofday( &start, NULL );
    return (double)((start.tv_sec) + 1.0e-6 * (start.tv_usec)) * 1000; //in milliseconds
}

double gflops_to_perform(int num, int channels_in, int height_in, int width_in,
                    int poolPad, int kernelSize, int poolStride, int num_output)
{

    double flops = 0.0f;

    int pooled_height = static_cast<int>(ceil(static_cast<float>(
        height_in + 2 * poolPad - kernelSize) / poolStride)) + 1;
    int pooled_width = static_cast<int>(ceil(static_cast<float>(
        width_in + 2 * poolPad - kernelSize) / poolStride)) + 1;

    // Calculate flops in a very pro way
    for (int n = 0; n < num; ++n) {
      for (int c = 0; c < channels_in; ++c) {
        for (int ph = 0; ph < pooled_height; ++ph) {
          for (int pw = 0; pw < pooled_width; ++pw) {
            int hstart = ph * poolStride - poolPad;
            int wstart = pw * poolStride - poolPad;
            int hend = min(hstart + kernelSize, height_in + poolPad);
            int wend = min(wstart + kernelSize, width_in + poolPad);
            hstart = max(hstart, 0);
            wstart = max(wstart, 0);
            hend = min(hend, height_in);
            wend = min(wend, width_in);
	    int pool_size = (hend - hstart) * (wend - wstart);
            flops += pool_size + 1.0f;
          }
        }
      }
    }

    return flops * 10e-9;
}

//set up and benchmark layers without actually having a network.
template<typename Dtype>
int avgpool_speed_test(int num, int channels_in, int height_in, int width_in,
                    int kernelSize, int poolPad, int poolStride, int num_output, string niceName)
{
    Blob<Dtype>* blob_bottom_ = new Blob<Dtype>(num, channels_in, height_in, width_in);
    Blob<Dtype>* blob_top_ = new Blob<Dtype>();
    vector<Blob<Dtype>*> blob_bottom_vec_;
    vector<Blob<Dtype>*> blob_top_vec_;
    blob_bottom_vec_.push_back(blob_bottom_); //PoolingLayer likes vectors of blobs.
    blob_top_vec_.push_back(blob_top_);

    LayerParameter layerParams; 
    layerParams.set_type(LayerParameter_LayerType_POOLING);

    PoolingParameter *poolParams = layerParams.mutable_pooling_param();
    // Max is set by default, but just to be explicit
    poolParams->set_pool(PoolingParameter_PoolMethod_AVE);
    poolParams->set_kernel_size(kernelSize);
    poolParams->set_pad(poolPad); // Need to define poolPad
    poolParams->set_stride(poolStride);

    PoolingLayer<Dtype> poolLayer(layerParams);
    poolLayer.SetUp(blob_bottom_vec_, &(blob_top_vec_));

    // THE BENCHMARK:
    int num_runs = 10;
    double start = read_timer();
    for (int j = 0; j < num_runs; ++j)
    {
        poolLayer.Forward(blob_bottom_vec_, &(blob_top_vec_));
    }
    CUDA_CHECK(cudaDeviceSynchronize()); //for accurate timing
    double layerTime = (read_timer() - start)/num_runs; 
    double gflops_performed = gflops_to_perform(num, channels_in, height_in, width_in,
                                                poolPad, kernelSize, poolStride, num_output);
    double gflops_per_sec = gflops_performed / layerTime * 1000; //*1000 for ms to sec 
    LOG(ERROR) << "    " << niceName <<  " forward: " << layerTime << " ms, " << gflops_performed << " gflops ... " << gflops_per_sec << " gflops/sec"; 

    delete blob_bottom_;
    delete blob_top_;
 
    return 0; //TODO: return 1 if error?
}

//mimic alexnet dims, print out perf results.
void alexnet_speed_test()
{
    int NUM_ = 50;
    
    // alexnet conv1
    avgpool_speed_test<float>(NUM_, 3, 227, 227, 
                           1, 11, 4, 96, "alexnet conv1");

    //pool1: stride=2

    avgpool_speed_test<float>(NUM_, 96, 27, 27,
                           2, 5, 1, 256, "alexnet conv2");

    //pool2: stride=2

    avgpool_speed_test<float>(NUM_, 256, 13, 13,
                           1, 3, 1, 384, "alexnet conv3"); //slightly faster than in net_speed_test_forrest (15ms vs 20ms, in GPU mode)

    //there is no pool3

    avgpool_speed_test<float>(NUM_, 384, 13, 13,
                           2, 3, 1, 384, "alexnet conv4");
    //there is no pool4

    avgpool_speed_test<float>(NUM_, 384, 13, 13,
                           2, 3, 1, 256, "alexnet conv5");

    //TODO: sweep the space of kernelSize, stride, channels, num_output, etc.

    LOG(ERROR) << "*** Benchmark ends ***";
}

// for the configuration below, bigger planes seem to give more gflops/s.
// inputDim=8 and inputDim=16 both take ~20ms.
void vary_input_size(){
    LOG(ERROR) << "running 'vary input size'";

    //experimentally, there doesnt seem to be much pwr-of-2 sensitivity 
    for(int inputDim = 8; inputDim <= 128; inputDim = inputDim*2){ //out of memory if >=128.
        ostringstream niceName;
        niceName << "inputDim = " << inputDim << ".";

        avgpool_speed_test<float>(50, 384, inputDim, inputDim,                           
                               3, 2, 1, 256, niceName.str());
        LOG(ERROR) << "running running run";
    }
}

//3x3 filter is as good as bigger filters in terms of gflops/s (~1700 gflops/s with 55x55 planes.)
void vary_filter_size(){
    LOG(ERROR) << "running 'vary filter size'";
    for(int filterSize=1; filterSize<10; filterSize++) //out of memory if >10
    { 
        ostringstream niceName;
        niceName << "filterSize = " << filterSize << ".";

        avgpool_speed_test<float>(50, 384, 55, 55, 
                               2, filterSize, 1, 256, niceName.str());
    }
}

void vary_channels_in(){
    LOG(ERROR) << "running 'num input channels'";
    for(int channels_in=4; channels_in <= 2048; channels_in=channels_in*2) //
    { 
        ostringstream niceName;
        niceName << "channels_in = " << channels_in << ".";

        avgpool_speed_test<float>(50, channels_in, 55, 55, 
                               3, 2, 1, 256, niceName.str());
    }
/*

int avgpool_speed_test(int num, int channels_in, int height_in, int width_in,
                    int kernelSize, int poolPad, int poolStride, int num_output, string niceName)
*/
}

void vary_batch_size()
{
    LOG(ERROR) << "running 'num batch size'";
    for(int NUM_=1; NUM_<60; NUM_+=4)
    { 
        ostringstream niceName;
        niceName << "NUM_ = " << NUM_ << ".";

        avgpool_speed_test<float>(NUM_, 384, 55, 55, 
                               2, 3, 1, 256, niceName.str());
    }
}

void vary_num_groups()
{
    LOG(ERROR) << "running 'num groups'";
    for(int group=1; group<=8; group=group*2)
    { 
        ostringstream niceName;
        niceName << "num groups = " << group << ".";

        avgpool_speed_test<float>(50, 384, 55, 55, 
                               group, 3, 1, 256, niceName.str());
    }
}

void vary_num_filters()
{
    LOG(ERROR) << "running 'num filters'";
    for(int num_output = 2; num_output < 10000; num_output=num_output*2)
    { 
        ostringstream niceName;
        niceName << "num filters = " << num_output << ".";

        avgpool_speed_test<float>(50, 384, 55, 55, 
                               2, 3, 1, num_output, niceName.str());

/*

int avgpool_speed_test(int num, int channels_in, int height_in, int width_in,
                    int kernelSize, int poolPad, int poolStride, int num_output, string niceName)
*/
    }
}

int main(int argc, char** argv) {
    ::google::InitGoogleLogging(argv[0]);
    cudaSetDevice(0);
    Caffe::set_mode(Caffe::CPU);
    Caffe::set_phase(Caffe::TEST);

    vary_input_size();

    return 0;
}
